---
title: Troubleshooting
nav_order: 7
---

# Troubleshooting

Real failure modes we (or other operators) have hit, and the fastest
path to a fix. If you run into something not listed here, open an
issue with the exact command, the scheduler stderr, and the affected
run id.

## Start here: `cronlord doctor`

Before reading further, run:

```sh
./cronlord doctor
```

It probes binary, config, data dir, DB integrity, pending migrations,
log dir size vs retention, stuck runs, worker heartbeats, tzdata,
admin token posture, private-net guard, and the Claude CLI in under a
second. Every item it flags has a fix in this file. Exit codes:
`0 = healthy`, `1 = warnings only`, `2 = at least one failure` — so
`cronlord doctor || exit 1` drops straight into a healthcheck.

For structured output (monitoring pipelines), use `cronlord doctor --json`.

## Installation and startup

### `shards build` fails on Alpine with "cannot find -lsqlite3"

You're on an Alpine-based container with the headless variant of the
SQLite package. Install the static libs:

```sh
apk add --no-cache sqlite-static openssl-libs-static \
  pcre2-dev zlib-static gc-dev
```

`Dockerfile.release` already does this.

### Scheduler exits with "schema migration failed"

One of the `db/migrations/*.sql` files couldn't apply. Check
`stderr` for the migration number. Most common causes:

- You rolled back to an older binary after running a newer migration.
  Migrations are forward-only; restore the DB from the backup that
  pre-dates the newer binary.
- A prior run left partial state. Run `sqlite3 cronlord.db 'PRAGMA
  integrity_check;'`; if it isn't `ok`, restore from a backup.

### Port 7070 already in use

Something else is bound. Either stop it, or bind CronLord elsewhere:

```sh
CRONLORD_HOST=127.0.0.1 CRONLORD_PORT=17070 ./cronlord server
```

## Jobs don't fire

### `/healthz` returns 200 but nothing runs

Usual suspects, in order:

1. **Bad cron expression.** The parser accepts the job but the next
   fire is far in the future (e.g. `0 0 31 2 *` never matches in a
   non-leap February). Hit `/api/cron/explain?expr=<your-expr>` to
   see the next 3 fires. Fix the expression or delete the job.
2. **Disabled job.** `enabled = false` means it stays in the list but
   the scheduler skips it. Toggle it in the UI or `POST /api/jobs`
   with `"enabled": true`.
3. **`max_concurrent` cap hit.** If a previous run is still
   `running` and the cap is `1`, the scheduler skips this tick. Cancel
   the stuck run (`POST /api/runs/<id>/cancel`) or raise
   `max_concurrent`.
4. **Timezone mismatch.** A job with `timezone = "America/New_York"`
   and `schedule = "0 9 * * *"` fires at 9 a.m. New York time, not
   UTC. Cron preview in the editor shows the actual wall-clock fires.

### Every run is `timeout` but the command runs fast locally

`timeout_sec` is wall-clock, not CPU. If the command blocks on I/O
(network, locks, a prompt), the deadline hits. Raise `timeout_sec`
or fix the blocking I/O.

### Runs stuck in `running`

- **Local runs** (`executor = "local"`): usually a crash of the
  scheduler mid-run. At next start, `Reaper.reap_zombies!` flips
  those rows to `fail`. If you see stuck rows after a clean restart,
  there's a bug; open an issue with the run id.
- **Worker runs** (`executor = "worker"`): the worker crashed or
  partitioned. Once `lease_expires_at` passes, the lease reaper
  (30 s tick) re-queues them. If they stay stuck, the worker is
  still heartbeating a ghost run - restart the worker.

## Web UI

### SSE log tail is blank on a running job

Reverse proxy is buffering. For nginx, add:

```nginx
proxy_buffering off;
proxy_cache off;
proxy_read_timeout 1h;
```

Caddy and Cloudflare Tunnel do not buffer SSE by default.

### Live cron preview doesn't update

The editor calls `/api/cron/explain`. If that returns `400` you
have an unparseable schedule; the preview will be blank until the
field is valid. Check the browser console network tab.

### "Cancel" button does nothing

Only `queued` and `running` rows are cancellable. `success`, `fail`,
`timeout`, and `cancelled` rows return `409 Conflict`. Check the
current `status` - the UI auto-refreshes, so stale dashboard data
can hide a terminal state.

## API

### `401 Unauthorized` on every request

You have `admin_token` set but aren't sending it. Use either:

```sh
curl -H "Authorization: Bearer $TOK" http://cron:7070/api/jobs
curl "http://cron:7070/api/jobs?token=$TOK"   # less preferred
```

The UI routes are not token-gated; only `/api/*` is.

### `POST /api/jobs` returns `400 bad timezone`

The IANA zone isn't installed on the host. Install `tzdata`
(Alpine: `apk add tzdata`) or switch to `UTC`.

### `POST /api/workers/lease` returns `401` even with a signature

Clock skew. The server rejects requests where `|now - timestamp| >
60 seconds`. Sync NTP on the worker host.

### Worker finishes a run but the scheduler shows `fail` with "worker cancelled"

The scheduler received `/api/workers/finish` after an operator
cancellation hit `/api/workers/heartbeat`. The heartbeat returned
`410 Gone` and the worker aborted. The run was cancelled; the
finish call arrived after that. Nothing to fix.

## Notifications

### Slack webhook URL rejected

CronLord refuses Slack-shaped payloads to non-Slack URLs on purpose.
The URL must start with `https://hooks.slack.com/`. Use
`webhook_url` (the generic JSON channel) for non-Slack destinations.

### Slack block shows `[fail]` but the message has no detail

Your Slack incoming webhook has message formatting disabled, or the
Slack app blocks Block Kit. Upgrade the incoming webhook app or
switch to the generic `webhook_url` + your own forwarder.

### Webhook never arrives

Failures log to stderr with `[notifier]` prefixed. Common reasons:

- TLS verification fails against a self-signed endpoint. Terminate
  TLS in front of the endpoint with a real cert.
- `CRONLORD_BLOCK_PRIVATE_NETS=1` and your webhook is on an
  RFC1918 address. Either unset the guard or add the target to a
  public proxy.
- The endpoint returned a 5xx three times; delivery was dropped.
  Check the endpoint logs.

## Claude runner

### Runs end with `fail` and "claude cli not found"

Install the [Claude Code CLI] and make sure it's on the scheduler's
`$PATH`. If you keep it under a non-standard path, set
`CRONLORD_CLAUDE_CLI=/opt/claude/bin/claude` (env) or add the same
via `systemd`'s `Environment=`.

[Claude Code CLI]: https://github.com/anthropics/claude-code

### Runs hang

Add a `timeout_sec` to the job. `claude -p` can block waiting on
tool approval if the CLI is misconfigured; a wall-clock timeout is a
cheap safety net.

### Long prompts get truncated in the log

The log captures everything; the command echo in the log buffer
redacts the prompt to `<prompt>` so the argv doesn't clutter the
output. If you want to see exactly what was passed, log the prompt
from within the job itself (`echo "$PROMPT"` in a wrapper).

## Database

### "Database is locked"

WAL mode with `busy_timeout=5000` handles normal concurrency. If you
hit this:

- Two schedulers running against the same DB. Only one allowed.
- An `sqlite3` shell holding a write lock. Close it.
- NFS/network storage with weak locking. Move the DB to local disk.

### DB file growing large

SQLite doesn't shrink `.db` files automatically. Run
`VACUUM` during a maintenance window:

```sh
systemctl stop cronlord
sqlite3 /var/lib/cronlord/cronlord.db 'VACUUM;'
systemctl start cronlord
```

Run logs (not DB rows) are auto-rotated per `CRONLORD_LOG_TTL_DAYS`.

## Still stuck?

- Run `./cronlord --version` and `./cronlord migrate` - confirm
  binary and schema are in sync.
- Tail stderr with `-v`: there isn't a `-v` flag yet, but all
  background fibers log to stderr with a bracket prefix
  (`[scheduler]`, `[reaper]`, `[notifier]`, `[worker]`).
- File an issue at
  <https://github.com/kdairatchi/CronLord/issues> with the binary
  version, OS, command, and the stderr around the failure.
