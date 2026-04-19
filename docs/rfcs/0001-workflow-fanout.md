---
rfc: 0001
title: Workflow + fanout job kinds
status: draft
author: kdairatchi
created: 2026-04-19
---

# RFC-0001: Workflow + fanout job kinds

## Summary

Add two new job kinds to CronLord: `workflow` (run a command only after a
named set of other jobs have succeeded in the current window) and `fanout`
(run a command once per input item with bounded concurrency, optionally
followed by a reducer step). Both are opt-in; existing jobs are unaffected.

## Motivation

Three user stories today cannot be expressed without external tools:

1. **Fan-in digest.** I run `subdomain-monitor`, `nuclei-scan`, and
   `h1-sweep` every morning. I want a `daily-digest` that runs
   *after* all three finish and only if they all succeeded.
2. **Fanout.** I have 200 bug-bounty targets in a text file. I want one
   scheduled job that spawns N parallel child runs, one per target,
   with a concurrency cap.
3. **Map-reduce.** A fanout across N targets followed by a reducer step
   that merges all child outputs into a single artifact.

Today you either chain jobs via `webhook_url` (fragile, no ordering
guarantee, doubles run count), or you introduce Airflow/Dagster (massive
overkill for a tool whose whole pitch is "one binary, one TOML").

The new kinds fit CronLord's existing primitives (runs, statuses, logs,
SSE, retries, timeouts) — they don't introduce a new execution engine.

## Design

### Non-goals

- Full DAG with diamond dependencies. Fan-in only. Real DAGs are a v2
  conversation.
- Triggering upstream jobs. `workflow` depends on jobs *as they run on
  their own schedules*. It does not wake them.
- Cross-host coordination. Local scheduler only at first; worker
  support tracked separately (see `deployment.md`).

### `workflow` kind

```toml
[[jobs]]
id       = "daily-digest"
kind     = "workflow"
schedule = "30 14 * * *"          # after the jobs it waits on
timezone = "UTC"

depends_on   = ["subdomain-monitor", "nuclei-scan", "h1-sweep"]
window_sec   = 86400              # how far back to look for dep success
on_missing   = "skip"             # skip | fail | run
on_dep_fail  = "skip"             # skip | fail | run

command = "/opt/jobs/digest.sh"   # or JSON for http, same contract as shell/http kinds
```

**Semantics**

At the job's next scheduled fire time:

1. For each `depends_on[]` id, query the latest run within the last
   `window_sec` seconds.
2. If every dep has a `status = "success"` run inside the window → execute
   `command` using the resolved inner kind (`shell`, `http`, `claude`).
3. If any dep has no run in the window → follow `on_missing`.
4. If any dep has a `fail` or `timeout` run in the window → follow
   `on_dep_fail`.

The workflow's own run has a status of `skipped` when it declines to
execute. The UI distinguishes skipped from failed.

**Why pull, not push?** The dep jobs don't need to know they have
downstream consumers. They run on their own schedules with no coupling.
The workflow job is the single point of coordination.

**Inner kind resolution.** `command` uses the same parsing rules as
today — a bare string = shell, a JSON object with `method`/`url` = http.
A new optional `inner_kind` field can force `claude`:

```toml
inner_kind = "claude"
command    = "Read the three dep artifacts in /var/lib/cronlord/digests and write a summary."
```

### `fanout` kind

```toml
[[jobs]]
id       = "scan-targets"
kind     = "fanout"
schedule = "0 6 * * *"

inputs_from = "file:///etc/cronlord/targets.txt"
# or "http://...", or "sql://main?SELECT url FROM targets WHERE enabled = 1"
# or "job://subdomain-monitor?output_as_lines"

concurrency          = 4
per_item_timeout_sec = 1800
partial_tolerance    = 0.1   # tolerate up to 10% child failures before parent fails

item_var = "FANOUT_ITEM"     # env var each child sees
command  = "nuclei -u $FANOUT_ITEM -silent -o /var/lib/cronlord/nuclei/$FANOUT_ITEM.log"

[jobs.reducer]
command = "python3 /opt/jobs/digest.py /var/lib/cronlord/nuclei"
run_on  = "success"          # success | always | any_success
```

**Semantics**

At scheduled fire time:

1. Resolve `inputs_from` → ordered list of items.
2. Create a parent run. Spawn up to `concurrency` child runs. Each child
   sees `FANOUT_ITEM` and a `CRONLORD_PARENT_RUN_ID` env var.
3. As children finish, start more until the list is exhausted.
4. When all children complete:
   - compute failure ratio
   - parent status = `success` if ratio ≤ `partial_tolerance`, else `fail`
   - parent status may be `partial` if `partial_tolerance > 0` and ratio > 0
5. Run `reducer.command` based on `reducer.run_on`. Reducer inherits
   parent timeout.

**Storage changes**

Add to the `runs` table:

```
parent_run_id   INTEGER NULL    -- REFERENCES runs(id)
item            TEXT    NULL    -- the FANOUT_ITEM value
role            TEXT    NULL    -- 'parent' | 'child' | 'reducer' | NULL
```

UI lists children nested under parent. SSE streams events for all three
roles.

### Input resolvers for `fanout`

| Scheme | Example | Behavior |
| --- | --- | --- |
| `file://` | `file:///etc/cronlord/targets.txt` | One non-empty non-`#` line per item. |
| `http(s)://` | `https://api.example.com/targets` | Fetch, require text/plain or JSON array. |
| `sql://` | `sql://main?SELECT url FROM t WHERE enabled=1` | Use an admin-registered DSN. First column per row. |
| `job://` | `job://subdomain-monitor?output_as_lines` | Read stdout of that job's most recent successful run within `window_sec`. |

Resolvers live in `src/cronlord/runner/fanout/resolvers/`, one file each.
Keeps auth and SSRF isolation per resolver.

## Retries

- `workflow`: retries apply to the inner command only, not to waiting on
  deps. A failed `workflow` run stays failed; next schedule re-checks.
- `fanout`: per-child retry controlled by the parent's `retry_count`. The
  parent doesn't re-fanout; a child that exhausts retries counts as a
  failed child.

## Cancellation

- Cancelling a `workflow` run cancels the inner command if running.
- Cancelling a `fanout` parent: pending children never start; running
  children receive SIGTERM (then SIGKILL 2s later). Reducer doesn't run.

## Worker executor

`workflow`: trivially worker-safe (same contract as shell/http/claude).
`fanout`: parent runs on the scheduler only (it owns the run graph); each
child may be dispatched to a worker as today. Concurrency counts
globally, not per worker.

## Security

- `inputs_from = "http://..."` — resolver enforces scheme allowlist
  (`http`, `https`), no redirects to private IPs in production mode.
- `inputs_from = "sql://..."` — DSN registered via admin UI only;
  never constructed from job config directly.
- `inputs_from = "job://..."` — can only read from jobs in the same
  CronLord instance, not across hosts.
- Children inherit parent's `env` — so secrets in parent env are visible
  to children. Document this.

## CLI + API surface

```
POST /api/jobs                    # existing, accepts kind = workflow | fanout
GET  /api/runs?parent_run_id=123  # new filter
GET  /api/runs/123/children       # convenience endpoint
```

No breaking changes to existing endpoints.

## UI

- Workflow: render `depends_on` badges with per-dep status dots.
- Fanout: parent run row is expandable, showing N child rows + 1 reducer
  row. Each child row shows its `item` value.

## Open questions

1. **Sharded SQLite writes for 1000-child fanouts.** Do we need a
   write-queue? Likely yes; punt to benchmarking.
2. **Priority across fanout children** vs. regular jobs — FIFO or
   starvation-free? Start with FIFO.
3. **Retry budget** — a workflow with 3 failing deps is wasting the
   retry slot daily. Add a `cooldown_sec` so it stops re-checking the
   same day?
4. **Reducer retry** — share the parent's retry, or independent?
   Proposed: independent, defaulting to 0.
5. **Fanout on dynamic input** — what if `inputs_from` returns 0 items?
   Parent finishes immediately; reducer runs iff `run_on = "always"`.

## Migration

Opt-in. Existing TOML files and DB rows need no change. Schema migration
adds nullable columns to `runs`; default values keep old rows valid.

## Rollout

1. Land `workflow` first — smaller blast radius, no new storage shape
   beyond a single lookup helper.
2. Land `fanout` second — add the run-graph columns and the resolver
   framework together.
3. Ship docs update to `docs/job-kinds.md` in the same PR as each kind.

## Prior art

- GitHub Actions `needs:` (workflow-level DAGs, but on top of jobs).
- Nomad batch job's `parameterized`/`dispatch` (fanout).
- Dagster `@asset` graphs (DAG, heavier).
- systemd.timer + requires=/wants= (unit-level dependencies).

None of those map cleanly to a single-process cron scheduler. This RFC
keeps CronLord's spirit (one TOML block per thing) while covering the
real coordination gaps.

---

## Next steps

- Comments in this file OR open as GitHub issue:
  `gh issue create --repo kdairatchi/CronLord --title "RFC: workflow + fanout job kinds" --body-file docs/rfcs/0001-workflow-fanout.md`
- After comment dust settles, move to `status: accepted`, cut a tracking
  issue for each kind, and land in two PRs.
