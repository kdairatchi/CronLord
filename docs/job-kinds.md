# Job Kinds

CronLord v0.1 ships three job kinds: `shell`, `http`, and `claude`. Each
runs in the scheduler's process (no remote workers needed in v0.1) and
writes its output to a per-run log file streamed back over SSE.

## shell

Runs the `command` field under `/bin/sh -c`. Stdout and stderr are merged
into the run log.

- **Command format:** any shell snippet. Quote shell metacharacters.
- **Working directory:** optional `working_dir` field (defaults to the
  scheduler's cwd, typically `/var/lib/cronlord` under systemd).
- **Environment:** per-job env vars layer on top of the scheduler's env.
  Don't rely on this for secrets - the values land in the DB as plain
  text; use a secret manager that exports at runtime.
- **Timeout:** `timeout_sec` > 0 sends SIGTERM at the deadline, SIGKILL
  2 seconds later. Exit status becomes `timeout`.

Example:

```toml
[[jobs]]
id       = "nightly-backup"
name     = "Backup DB"
schedule = "0 3 * * *"
kind     = "shell"
command  = "pg_dump -Fc mydb | aws s3 cp - s3://backups/mydb-$(date -I).dump"
working_dir = "/var/lib/backup"
timeout_sec = 1800
```

### Exit codes

| Exit | Status in UI |
| --- | --- |
| `0` | `success` |
| non-zero | `fail` |
| SIGTERM after timeout | `timeout` |

## http

Calls an HTTP endpoint. The `command` field can be either a plain URL
(executes a `GET` with no body) or a JSON object describing the full
request.

### Plain URL form

```
https://api.example.com/cron/daily-rollup
```

### JSON form

```json
{
  "method": "POST",
  "url": "https://api.example.com/webhook",
  "headers": {
    "Content-Type": "application/json",
    "X-Signing-Secret": "rot-your-own-secret"
  },
  "body": "{\"source\":\"cronlord\"}",
  "expect_status": 200,
  "follow": true
}
```

Fields:

- `method` - any standard HTTP verb. Default `GET`.
- `url` - required. Scheme must be `http` or `https`. The runner rejects
  `file://`, `gopher://`, and anything non-web to avoid SSRF from stored
  credentials.
- `headers` - map of header name -> value.
- `body` - request body as a string (not an object - encode it yourself
  to keep the contract predictable).
- `expect_status` - integer or array of integers. If set, any other
  response code is treated as a failure. Default: `2xx` is success.
- `follow` - follow redirects. Default `true`.

### Response handling

The runner logs the status line, the first 32 KB of the response body,
and the total elapsed time. The run is marked `fail` if:

- The status code does not match `expect_status`.
- The connection is refused or times out.
- The URL scheme isn't `http`/`https`.

## claude

Runs `claude -p <prompt>` using the local [Claude Code CLI]. Useful for
agent-style scheduled tasks - a 5 a.m. repo scan, a weekly vault
summary, a nightly secret-rotation check.

[Claude Code CLI]: https://github.com/anthropics/claude-code

### Requirements

- The `claude` CLI must be on the scheduler's `$PATH`. Override the
  binary name with `CRONLORD_CLAUDE_CLI=/usr/local/bin/claude`.
- The CLI must be logged in (typically `claude login` once on the box).

### Command format

The `command` field is the prompt verbatim. CronLord passes it as a
single argument to `claude -p`.

### Optional args

Add a `model` field to the job's `args` JSON (via API or TOML) to pin a
model:

```json
{
  "kind": "claude",
  "command": "Summarize today's /var/log/syslog and flag anything unusual.",
  "args": { "model": "claude-haiku-4-5-20251001" }
}
```

### Example

```toml
[[jobs]]
id       = "weekly-vault-summary"
name     = "Summarize vault changes"
schedule = "0 9 * * 1"
kind     = "claude"
command  = "Read the last 7 daily notes in /mnt/vault and write a one-page summary to /mnt/vault/summaries/week.md"
timeout_sec = 600
```

## Choosing between them

| Need | Use |
| --- | --- |
| Anything that already runs in a shell | `shell` |
| Hitting a webhook, health check, or your own API | `http` |
| A prompt-driven task that calls out to Claude | `claude` |
| Mixing all three | write three jobs, chain with webhooks |

Retries and webhook notifications work identically across all three
kinds. The job editor shows kind-specific help next to the command
field so you don't have to remember the JSON schema.

## Notifications

Every job can carry two optional webhook fields, delivered in parallel
by a best-effort fiber when a run reaches a terminal status (`success`,
`fail`, `timeout`, or `cancelled`).

| Field | Shape | Purpose |
| --- | --- | --- |
| `webhook_url` | `POST` JSON with `job_id`, `run_id`, `status`, `exit_code`, `started_at`, `finished_at`, `error`, `trigger` | Generic automation (PagerDuty, custom dashboards, Zapier, ...). |
| `slack_webhook_url` | `POST` Slack Block Kit (`text` + `blocks`) | Slack channel posts. |

The Slack field must begin with `https://hooks.slack.com/` - anything
else is refused so that a misconfigured or attacker-controlled URL can't
receive the Slack-shaped payload. Status appears as a text tag
(`[ok]`, `[fail]`, `[timeout]`, `[cancelled]`), never an emoji, so the
message reads the same regardless of the recipient's client.

Both channels retry up to three times with a two-second gap and log to
stderr when they give up; failures never block the scheduler.

## Timezones

Each job has a `timezone` column (default `UTC`). The scheduler resolves
it through Crystal's `Time::Location`, so any IANA zone your host
supports works - `America/New_York`, `Europe/Berlin`, `Asia/Tokyo`, etc.
The value is validated at save time; an unknown zone is rejected with
`400`.

DST is handled the POSIX-cron way:

- On spring-forward, the missing wall-clock hour (`02:00`-`02:59` in the
  US) doesn't fire that day.
- On fall-back, the repeated wall-clock hour fires exactly once, on the
  first occurrence. A subsequent `next_after` call picks up from the
  next day.

The live cron preview in the job editor re-queries `/api/cron/explain`
whenever the timezone field changes, so you see the fires in the zone
the job will actually use before you save.
