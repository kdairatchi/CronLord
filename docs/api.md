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

Remote workers authenticate with a shared secret issued when they
register. Every signed request carries:

- `X-CronLord-Timestamp: <unix_seconds>`
- `X-CronLord-Signature: <hex-sha256>`

### Canonical string

```
"<timestamp>\n<request body>"
```

### Signing (Crystal)

```crystal
sig, ts = CronLord::Auth::Hmac.sign(secret, body)
headers["X-CronLord-Timestamp"] = ts.to_s
headers["X-CronLord-Signature"] = sig
```

### Signing (sh)

```sh
ts=$(date +%s)
body='{"worker":"runner-1"}'
sig=$(printf '%s\n%s' "$ts" "$body" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')
curl -H "X-CronLord-Timestamp: $ts" \
     -H "X-CronLord-Signature: $sig" \
     -H "Content-Type: application/json" \
     --data "$body" \
     http://cronlord:7070/api/workers/lease
```

### Skew window

The server rejects requests where `|now - timestamp| > 60 seconds`. Sync
the worker's clock (NTP) or raise the window by overriding the skew
argument in your own verifier.

### Verification on the server side

```crystal
CronLord::Auth::Hmac.verify!(secret, body, timestamp, signature)
# raises VerifyError on mismatch or skew
```

`verify?` returns `true` / `false` without raising.

### Worker registration

Not exposed over HTTP in v0.1 — use the CLI or a Crystal one-liner:

```crystal
worker, plaintext_secret = CronLord::Worker.register("runner-1", labels: ["linux", "gpu"])
puts "id: #{worker.id}"
puts "secret (copy once): #{plaintext_secret}"
```

The plaintext secret is only returned once. Only its SHA-256 hash is
stored in the `workers` table.

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
