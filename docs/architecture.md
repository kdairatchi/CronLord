---
title: Architecture
nav_order: 8
---

# Architecture

CronLord is roughly 3 000 lines of Crystal split across a scheduler, a set
of runners, an HTTP server, and a UI. Everything lives in one process
and one binary.

## Process layout

```
+--------------------------------------------------------+
|  cronlord server                                       |
|                                                        |
|  +-------------+   +--------------+   +--------------+ |
|  |  Scheduler  |-->|   Runners    |-->|  LogBuffer   | |
|  |  (tickless) |   | shell / http |   | per-run file | |
|  +-------------+   | claude       |   +--------------+ |
|         |          +--------------+          ^         |
|         v                                    |         |
|  +-------------+   +--------------+           |        |
|  |   SQLite    |<--|  Kemal HTTP  |-----------+        |
|  |  (WAL + FK) |   |   UI + API   |   SSE streams      |
|  +-------------+   +--------------+                    |
|                           |                            |
|                           v                            |
|                    +--------------+                    |
|                    |   Notifier   |  -> webhook POST   |
|                    |  (spawn/fire)|                    |
|                    +--------------+                    |
+--------------------------------------------------------+
```

One OS process. Crystal fibers multiplex the scheduler loop, the HTTP
server, and every concurrent job runner.

## Scheduler

`src/cronlord/scheduler.cr`. Tickless:

1. Compute the `next_after(now)` time for every enabled job.
2. Sleep until the nearest one fires, or until the wakeup channel gets
   a signal (new job, edited schedule, `kick`).
3. Dispatch the due job to the right runner, mark the run `running`,
   attach stdout/stderr pumps to the log buffer.
4. Goto 1.

Two Channels drive the loop:

- `@wake : Channel(Nil)` - UI/API signal that the job set changed.
- `@stop : Channel(Nil)` - graceful shutdown on SIGTERM.

The scheduler never busy-loops. Idle CPU is literally zero.

### Retries

`schedule_retry` runs inside a separate fiber and uses exponential
backoff:

```
delay = min(base * 2^(attempt - 2), 1800)
```

Retries get a distinct `trigger = "retry-N"` so they don't loop through
`should_retry?` again.

### Concurrency caps

Each job has `max_concurrent`. The scheduler checks the number of
`running` rows for that job before firing; if the cap is hit the run is
skipped (not queued) and logged at the scheduler level. v0.2 will add
proper queueing.

### Executor split

Each job has an `executor` field:

- `local` - the scheduler spawns the runner in-process (default).
- `worker` - the scheduler creates the run row as `queued` and leaves
  it there. Remote workers poll `/api/workers/lease` to claim and
  execute it. See [API: Worker protocol](api.md#worker-protocol-hmac).

Workers heartbeat every `lease_sec / 2` seconds. If a worker crashes
or partitions, the `Reaper` fiber re-queues runs whose
`lease_expires_at` has passed (runs every 30 s). This keeps jobs
progressing even when a worker silently dies.

## Runners

Each runner exposes a single module-level `run(job, run, buffer) : Int32`
and is responsible for:

- Interpreting the `command` field for its kind.
- Piping stdout/stderr into the shared log buffer.
- Enforcing `timeout_sec` (SIGTERM, then SIGKILL 2 seconds later).
- Calling `run.mark_finished` with the right status.

The three runners share almost no code:

- **shell** (`runner/shell.cr`) - `Process.run("/bin/sh", ["-c", command])`
  with env inheritance + overrides.
- **http** (`runner/http.cr`) - parses plain URL or JSON, enforces the
  `http`/`https` scheme allowlist, captures status + 32 KB of body.
- **claude** (`runner/claude.cr`) - shells out to `claude -p <prompt>`;
  respects `args["model"]`.

Adding a new kind is ~100 lines: implement `run`, wire it in `scheduler.cr`,
add a `select` option in the job editor, document it.

## Log buffer

`src/cronlord/log_buffer.cr`. A thin wrapper around a per-run file in
`logs/<run_id>.log`:

- Two fibers pump stdout and stderr into the file line-by-line.
- The HTTP server reads the file directly for SSE streaming - no
  in-memory fan-out. This keeps the scheduler simple; the downside is
  that tail-follow on a live run is not yet implemented (the SSE
  stream sends the current file contents then an `end` event).

## Storage

`src/cronlord/db.cr` opens SQLite with `journal_mode=WAL`,
`synchronous=NORMAL`, `busy_timeout=5000`, and `foreign_keys=true`. The
only external dependency is `crystal-lang/crystal-sqlite3`.

Migrations are numbered SQL files under `db/migrations/`. A
`schema_migrations` table records which ones have been applied. The
runner strips line comments so trailing `--` comments inside statements
don't split them, and splits on top-level semicolons.

### Schema at a glance

- `jobs` - scheduling config (21 columns incl. `executor`, `labels_json`,
  args/env JSON blobs).
- `runs` - one row per execution; `status`, `exit_code`, `log_path`,
  `trigger`, `error`, `attempt`, plus `worker_id`, `lease_expires_at`,
  `heartbeat_at` for remote runs.
- `audit` - append-only; `at`, `actor`, `action`, `target`, `meta_json`.
- `workers` - registered remote workers (`id`, `name`, `secret_hash`,
  `labels_json`, `last_seen`).
- `tokens` - API tokens (schema stub; the admin token is still env/toml).
- `schema_migrations` - version tracking.

## HTTP server

`src/cronlord/server.cr`. Kemal for routing, ECR for views. The server
class holds the `Config` and the `Scheduler` so routes can call
`scheduler.kick` or `scheduler.trigger_now`.

Views live under `src/cronlord/views/` and are baked into the binary via
`ECR.render`. No build step.

### Views

- `layout.ecr` - the dock-window chrome (sidebar + topbar + content).
- `overview.ecr` - 4 KPI cards + "Next fires" + "Recent runs".
- `jobs_index.ecr` - table of all jobs.
- `job_edit.ecr` - 4-panel editor (Identity, Schedule, Command,
  Execution) with live cron preview via `/api/cron/explain`.
- `runs_index.ecr` - filterable run history.
- `run_show.ecr` - single-run detail with SSE log pane.
- `audit.ecr` - audit trail.
- `settings.ecr` - config dump + token info.

CSS is two files: `public/css/tokens.css` (design tokens) and
`public/css/base.css` (component rules). No build. No framework.

## Notifier

`src/cronlord/notifier.cr`. After `mark_finished`, the scheduler calls
`Notifier.deliver(job, run)`. If the job has `args["webhook_url"]`, the
notifier spawns a fiber that POSTs JSON with 3 retries at 2-second
intervals and a 5-second per-request timeout. Failures log to stderr
and never raise back into the scheduler.

## Security surfaces

- **API:** bearer token (env or TOML). No per-user accounts yet.
- **UI:** not authenticated in-process. Reverse-proxy it.
- **Workers:** HMAC-SHA256 with a 60-second skew window. Secrets are
  stored as SHA-256 hashes; the plaintext is returned once at register.
  The HMAC key is `sha256(plaintext)` - the worker hashes the plaintext
  locally once to derive the same key the server holds, so the server
  never sees the plaintext after registration.
- **Job inputs:** a `shell` command can do anything the scheduler's
  user can do. Don't expose the UI to untrusted users. Put it behind
  Tailscale / your SSO / Cloudflare Access.
- **HTTP runner:** scheme allowlist blocks `file://` and non-web
  protocols; otherwise any URL on the internet is fair game.

## Crystal trade-offs

Pros:

- Single static binary (thanks to `--static --release`).
- Ruby-ish syntax with C-class throughput. Idle RSS ~15 MB.
- Fibers give us "spawn a goroutine" ergonomics without Go's ecosystem.

Cons (honest):

- Smaller library ecosystem. We pay in code we write ourselves rather
  than `npm install`.
- Compile times are slow for a small project (10-20 s cold). Fine
  for a release binary, painful for live reload.
- Debugging Crystal fibers is less polished than Go. `stderr` is your
  friend.

## What's deliberately simple

- No React. Server-rendered ECR + htmx + a few dozen lines of JS.
- No job queue. The scheduler *is* the queue.
- No database abstraction. Crystal DB shards talks SQLite directly.
- No config reload. Edit the TOML and restart; startup is <1 s.

## What's deliberately missing today

- Distributed scheduler (one leader, horizontal workers are supported
  via the lease protocol, but there's still only one scheduler
  process).
- Per-user accounts.
- Built-in TLS. Reverse-proxy it.
- Tail-follow on live run logs (the SSE stream delivers the current
  file then an `end` event; Kemal -> SSE tail is on the roadmap).
