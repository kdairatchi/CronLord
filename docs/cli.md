# CLI Reference

The `cronlord` binary is the whole product. This page catalogues every
subcommand, flag, and environment variable it honours, so you can
script against it or drop it into an `ExecStart=` line with confidence.

## Global flags

```
-c, --config PATH          path to cronlord.toml (default: ./cronlord.toml)
-h, --help                 show help
-V, --version              print version and exit
```

Unknown top-level flags are forwarded to the subcommand. Subcommand
flags like `--schedule` on `job add` don't conflict.

## Global environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `CRONLORD_HOST` | `127.0.0.1` | Listen host |
| `CRONLORD_PORT` | `7070` | Listen port |
| `CRONLORD_DATA` | `./var` | Data directory (db + logs live here) |
| `CRONLORD_DB` | `$DATA/cronlord.db` | SQLite path override |
| `CRONLORD_LOG_DIR` | `$DATA/logs` | Per-run log directory |
| `CRONLORD_ADMIN_TOKEN` | unset | Bearer token gating `/api/*` |
| `CRONLORD_LOG_TTL_DAYS` | `30` | Run log retention; `0` disables auto-rotation |
| `CRONLORD_BLOCK_PRIVATE_NETS` | unset | `1` refuses RFC1918, loopback, link-local, CGNAT, multicast HTTP targets |
| `CRONLORD_CLAUDE_CLI` | `claude` | Override Claude Code CLI binary for `kind = "claude"` jobs |

Env > `cronlord.toml` > built-in default.

## `cronlord serve` / `cronlord server`

Starts the scheduler + HTTP server + background reapers. This is the
everyday command.

```sh
./cronlord server
CRONLORD_ADMIN_TOKEN=$(openssl rand -hex 32) ./cronlord server
```

What runs in the process:

- **Scheduler** - tickless loop, wakes for the next due job.
- **HTTP server** - Kemal on `$CRONLORD_HOST:$CRONLORD_PORT`.
- **Log reaper** - deletes run logs older than `CRONLORD_LOG_TTL_DAYS`
  once per day. Skipped when `CRONLORD_LOG_TTL_DAYS=0`.
- **Lease reaper** - re-queues runs whose worker lease expired
  (every 30 s).

SIGINT / SIGTERM flushes the scheduler, closes the DB, and exits 0.

## `cronlord migrate`

Applies pending SQL migrations from `db/migrations/`. `serve` runs
migrations automatically on boot, so this is for manual maintenance
(e.g. running migrations against a snapshot before swapping binaries).

```sh
./cronlord migrate
# => ok
```

## `cronlord job <subcommand>`

Non-interactive CRUD for jobs. Respects `CRONLORD_ADMIN_TOKEN` only at
the HTTP surface - the CLI talks to the DB directly.

### `job list`

```sh
./cronlord job list
```

Columns: `ID`, `NAME`, `SCHEDULE`, `ON`, `COMMAND` (truncated at 60).

### `job add`

```sh
./cronlord job add \
  --schedule '*/5 * * * *' \
  --command 'ping -c1 example.com' \
  --name heartbeat
```

| Flag | Required | Notes |
| --- | --- | --- |
| `--schedule` | yes | Cron expression or `@hourly`/`@daily`/`@weekly`/`@monthly`. Parsed before write. |
| `--command` | yes | Shell snippet (for `--kind=shell`), URL/JSON (`http`), or prompt (`claude`). |
| `--name` | no | Display name; defaults to the id. |
| `--id` | no | Stable id; defaults to UUID. Useful for idempotent upserts. |
| `--timeout` | no | Seconds until SIGTERM -> SIGKILL. `0` = unlimited. |
| `--kind` | no | `shell` (default), `http`, `claude`. |

Prints the job id on success. Exits `2` with a message on bad input.

### `job rm <id>`

```sh
./cronlord job rm 3a4f...
# => deleted
# or => not_found
```

Cascades to runs via `ON DELETE CASCADE` in the schema.

### `job run <id>`

Triggers a run immediately (`trigger = "cli"`), blocks until it
finishes, prints the run id. Useful for manual smoke tests or
invoking a job from another cron.

```sh
./cronlord job run nightly-backup
```

## `cronlord runs [--job ID] [--limit N]`

Show recent runs. Defaults to 20 rows newest first. Filter to one
job with `--job=<id>`.

```sh
./cronlord runs --limit 5
./cronlord runs --job heartbeat --limit 50
```

## `cronlord worker <subcommand>`

Manages the remote worker registry. All subcommands except `run` talk
to the local DB.

### `worker register <name> [--label L]...`

Creates a new worker row with a random plaintext secret. **The
plaintext is printed once; there is no way to recover it.** Copy it,
then derive the HMAC key on the worker host with
`sha256(plaintext_secret)`.

```sh
./cronlord worker register runner-1 --label linux --label gpu
# id:     b1d7abd0-...
# name:   runner-1
# secret (shown once - copy it now):
# 47caaaeb19...
```

Labels are how `job.labels` restrict eligibility. A job with
`labels = ["linux"]` is only leased by workers advertising `linux`.
Empty `job.labels` means "any worker".

### `worker list`

```sh
./cronlord worker list
# b1d7abd0-...  runner-1  on   2026-04-19 11:42:01
# 5e02c1aa-...  runner-2  off  never
```

Columns: `id`, `name`, `enabled`, `last_seen` (unix -> local time).

### `worker rm <id>`

```sh
./cronlord worker rm b1d7abd0-...
# => deleted
```

Removes the worker row and detaches any in-flight leases (runs flip
back to `queued` via the lease reaper).

### `worker run`

Runs the reference worker polling loop. Expected environment (all
required, flags override each one-to-one):

| Env / flag | Purpose |
| --- | --- |
| `CRONLORD_URL` / `--url` | Scheduler base URL, e.g. `https://cron.example.com` |
| `CRONLORD_WORKER_ID` / `--id` | Worker id from `worker register` |
| `CRONLORD_HMAC_KEY` / `--key` | `sha256(plaintext_secret)` |
| `CRONLORD_WORKER_NAME` / `--name` | Display name (logs only; default: `hostname`) |
| `CRONLORD_LEASE_SEC` / `--lease` | Lease window, default `60` |
| `CRONLORD_POLL_SEC` / `--poll` | Idle poll interval, default `5` |

```sh
export CRONLORD_URL=https://cron.example.com
export CRONLORD_WORKER_ID=b1d7...
export CRONLORD_HMAC_KEY=$(printf '%s' "$PLAIN_SECRET" | openssl dgst -sha256 | awk '{print $2}')
./cronlord worker run --name "$(hostname)"
```

SIGINT / SIGTERM drains the current run (if any) and exits 0.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Domain failure (not found, unknown subcommand, ...) |
| `2` | Bad invocation (missing required flag, invalid cron) |

## See also

- [Getting Started](getting-started.md) - zero to first job.
- [API](api.md) - the REST surface, same CRUD as the CLI.
- [Deployment](deployment.md) - systemd, Docker, reverse proxies.
- [Troubleshooting](troubleshooting.md) - when something is wrong.
