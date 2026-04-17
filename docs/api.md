# API Reference

All endpoints under `/api/*` speak JSON. When `admin_token` is configured,
every request must present either an `Authorization: Bearer <token>`
header or a `?token=<token>` query string — the header is preferred.

Responses set `Content-Type: application/json`. Error responses use
standard HTTP status codes with an `{"error": "..."}` body.

## Health

### `GET /healthz`

Unauthenticated. Returns `{"status":"ok","version":"0.1.0"}`. Use for
liveness probes.

### `GET /api/version`

Unauthenticated. Returns `{"version":"0.1.0"}`.

## Jobs

### `GET /api/jobs`

Returns every job.

```sh
curl -H "Authorization: Bearer $TOK" http://localhost:7070/api/jobs
```

Response:

```json
[
  {
    "id": "heartbeat",
    "name": "heartbeat",
    "kind": "shell",
    "schedule": "*/1 * * * *",
    "timezone": "UTC",
    "command": "date -u",
    "enabled": true,
    "source": "api",
    "...": "..."
  }
]
```

### `GET /api/jobs/:id`

Returns one job or `404`.

### `POST /api/jobs`

Creates (or upserts) a job.

```sh
curl -XPOST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  http://localhost:7070/api/jobs -d '{
    "id": "heartbeat",
    "name": "heartbeat",
    "schedule": "*/1 * * * *",
    "command": "date -u",
    "kind": "shell"
  }'
```

Required fields: `schedule`, `command`. Optional fields match the
columns in `jobs` — see [Job Kinds](job-kinds.md) for kind-specific
options.

Returns `201` with the stored job. Writes `job.create` or `job.update`
to the audit log.

### `POST /api/jobs/:id/run`

Triggers a run *now* with `trigger = "api"`. Returns `202` with the run
row; the run id lets you follow its log over SSE.

### `DELETE /api/jobs/:id`

Removes a job (and cascades its runs). Returns `{"deleted": true|false}`.

## Runs

### `GET /api/runs?job_id=&limit=`

Recent runs, newest first. Filter by `job_id`; default `limit` is 100.

### `GET /api/runs/:id/log` (SSE)

Server-Sent Events stream of the run's log file. The stream finishes
with an `event: end` frame carrying the final status.

```sh
curl -N -H "Authorization: Bearer $TOK" \
  http://localhost:7070/api/runs/$RUN_ID/log
```

## Cron helpers

### `GET /api/cron/explain?expr=`

Unauthenticated (it's read-only, no data exposure). Returns:

```json
{
  "ok": true,
  "describe": "at minute */5",
  "next": "2026-04-17 14:30 UTC",
  "fires": [
    "2026-04-17 14:30 UTC",
    "2026-04-17 14:35 UTC",
    "2026-04-17 14:40 UTC"
  ]
}
```

Returns `400` with `{"ok":false,"error":"..."}` on parse failure. The
web UI's live preview calls this endpoint.

## Worker protocol (HMAC)

Jobs with `executor = "worker"` are queued but never spawned on the
scheduler host. Remote workers poll a lease endpoint, heartbeat while
they execute, and post a terminal status when done.

### Registering a worker

Not exposed over HTTP — register on the scheduler host:

```sh
cronlord worker register runner-1 --label linux --label gpu
# prints: worker id + plaintext secret (copy once)
```

Or from Crystal:

```crystal
worker, plaintext_secret = CronLord::Worker.register("runner-1", labels: ["linux", "gpu"])
```

Only `sha256(plaintext_secret)` is stored in the `workers` table.

### Deriving the HMAC key

The server never sees the plaintext secret after registration — it
only holds the SHA-256 hash. To produce the same HMAC key on the
worker, hash the plaintext locally once and use the hex digest as
the key material:

```sh
KEY=$(printf '%s' "$PLAIN_SECRET" | openssl dgst -sha256 | awk '{print $2}')
```

Store `$KEY` (not the plaintext) in the worker's config.

### Signed request headers

Every request to `/api/workers/*` carries:

- `X-CronLord-Worker-Id: <worker_id>`
- `X-CronLord-Timestamp: <unix_seconds>`
- `X-CronLord-Signature: <hex-sha256>`

Canonical string (newline-separated):

```
<timestamp>\n<raw request body>
```

Signing in shell:

```sh
ts=$(date +%s)
body='{"lease_sec":60}'
sig=$(printf '%s\n%s' "$ts" "$body" | openssl dgst -sha256 -hmac "$KEY" | awk '{print $2}')
curl -XPOST http://cronlord:7070/api/workers/lease \
  -H "X-CronLord-Worker-Id: $WORKER_ID" \
  -H "X-CronLord-Timestamp: $ts" \
  -H "X-CronLord-Signature: $sig" \
  -H "Content-Type: application/json" \
  --data "$body"
```

Signing in Crystal:

```crystal
sig, ts = CronLord::Auth::Hmac.sign(hmac_key, body)
```

The server rejects requests where `|now - timestamp| > 60 seconds` or
when the worker is disabled.

### `POST /api/workers/lease`

Claim the oldest queued run whose job targets this worker. Body:

```json
{"lease_sec": 60}
```

Responses:

- `200` with run + job payload when a run is leased
- `204` when nothing matches (poll again later)

```json
{
  "run_id": "374f2b6c-9d90-4d90-978a-33abbb118d45",
  "job": {
    "id": "reindex",
    "kind": "shell",
    "command": "/usr/bin/reindex",
    "executor": "worker",
    "labels": ["linux"],
    "timeout_sec": 600,
    "...": "..."
  },
  "lease_expires_at": 1776458465,
  "heartbeat_every": 30
}
```

Label matching: if the job's `labels` array is empty, any worker is
eligible; otherwise the worker must advertise at least one matching
label.

### `POST /api/workers/heartbeat`

Extend the lease. Call at least once per `heartbeat_every` seconds
(half the `lease_sec` the lease was granted for).

```json
{"run_id": "374f2b6c-...", "lease_sec": 60}
```

Returns `{"lease_expires_at": <unix>}` or `404` if the run is not
leased by this worker (possibly reaped — abort execution).

### `POST /api/workers/finish`

Report a terminal status and optionally upload the log.

```json
{
  "run_id": "374f2b6c-...",
  "status": "success",
  "exit_code": 0,
  "error": null,
  "log": "... captured stdout+stderr ..."
}
```

`status` should be `"success"`, `"fail"`, or `"timeout"`. Returns
`{"ok": true}`; also writes a `run.finish` audit row and triggers any
configured webhook.

### Lease expiry

The scheduler runs a lease reaper every 30 seconds. Runs whose
`lease_expires_at` has passed are flipped back to `queued` with
`worker_id` cleared, so another worker can pick them up.

## Audit

### `GET /audit` (HTML)

The web UI page. Not JSON, but documented here so operators can script
around it.

Audit rows are written for:

- `job.create`, `job.update`, `job.delete`
- `job.run` (manual trigger from UI or API — scheduler-fired runs are
  visible in the runs list, not the audit log)

Each row has `at`, `actor`, `action`, `target`, and free-form `meta_json`.

## Status codes summary

| Code | Meaning |
| --- | --- |
| `200 OK` | Successful read |
| `201 Created` | Job upserted |
| `202 Accepted` | Run queued |
| `400 Bad Request` | Invalid JSON or missing required fields |
| `401 Unauthorized` | Missing / wrong bearer token |
| `404 Not Found` | Job or run id does not exist |

## Rate limits

v0.1 has no built-in rate limiter. If you expose the API to the
internet, put it behind nginx / Caddy / Cloudflare and rate-limit
there. The scheduler itself is unaffected by API load — heavy polling
just adds SQLite read traffic.
