---
title: Getting Started
nav_order: 2
---

# Getting Started

Three install paths: Docker, the `install.sh` one-liner for systemd hosts,
and building from source. Pick whichever matches the box you're putting
this on.

## Option 1 - Docker

```sh
docker run -d --name cronlord \
  -p 7070:7070 \
  -v cronlord-data:/var/lib/cronlord \
  ghcr.io/kdairatchi/cronlord:latest
```

Or with `docker-compose.yml` in the repo root:

```sh
docker compose up -d
```

The image runs as a non-root `cronlord` user and stores everything under
`/var/lib/cronlord`. Mount a named volume there if you want the jobs
to survive container recreation.

## Option 2 - install.sh (systemd host)

```sh
curl -fsSL https://raw.githubusercontent.com/kdairatchi/CronLord/main/scripts/install.sh | sudo sh
```

The installer:

1. Creates a `cronlord` system user.
2. Downloads the latest release binary to `/usr/local/bin/cronlord`.
3. Writes a default config at `/etc/cronlord/cronlord.toml`.
4. Drops a hardened systemd unit.
5. Runs `systemctl enable --now cronlord`.

Confirm it's alive:

```sh
curl http://127.0.0.1:7070/healthz
# {"status":"ok","version":"0.3.6"}
```

## Option 3 - from source

You need Crystal 1.19 or newer and `shards`.

```sh
git clone https://github.com/kdairatchi/CronLord && cd CronLord
shards install
shards build cronlord --release
./bin/cronlord server
```

To run the test suite:

```sh
crystal spec
```

## Your first job

Open `http://localhost:7070/jobs/new`. Fill in:

- **Name:** `heartbeat`
- **Schedule:** `*/1 * * * *` (or click the "Hourly" preset)
- **Kind:** `shell`
- **Command:** `date -u`

Hit **Create job**. The next fire time appears on the overview.

Click **Run now** on the job detail page to trigger it immediately. The
run page streams stdout/stderr over SSE; you'll see today's date land in
the log pane.

## Securing the API

By default the HTTP API is open to anyone who can reach port 7070. To
require a bearer token, either set an environment variable:

```sh
CRONLORD_ADMIN_TOKEN="$(openssl rand -hex 32)" ./cronlord server
```

Or put it in `cronlord.toml`:

```toml
[server]
admin_token = "replace-me-with-a-long-random-string"
```

Every request to `/api/*` then needs either an `Authorization: Bearer <token>`
header or a `?token=` query parameter. The web UI is not token-gated
today - bind to `127.0.0.1` and front with a reverse proxy that handles
your existing auth (nginx basic auth, Cloudflare Access, Tailscale
Serve, etc.).

## Webhook notifications

Each job has an optional **Webhook URL** field in the editor. When set,
CronLord POSTs a JSON payload to that URL after every run (success or
failure):

```json
{
  "job_id": "heartbeat",
  "job_name": "heartbeat",
  "run_id": "...",
  "status": "success",
  "trigger": "schedule",
  "exit_code": 0,
  "started_at": 1700000000,
  "finished_at": 1700000001,
  "error": null
}
```

Delivery is fire-and-forget with 3 retries at 2-second spacing. Failures
are logged to stderr but never crash the scheduler.

## Declarative jobs via cronlord.toml

Editing jobs in the UI is fine for experimentation. For infrastructure
you control, pin them in `cronlord.toml`:

```toml
[[jobs]]
id       = "nightly-backup"
name     = "Nightly DB dump"
schedule = "0 3 * * *"
command  = "/usr/local/bin/backup.sh"
kind     = "shell"
timeout_sec = 1800
```

These jobs get `source = "toml"` and are re-upserted on every boot, so
they're immune to accidental UI deletes.

## Next

- [Job Kinds](job-kinds.md) - `shell` vs `http` vs `claude`.
- [API](api.md) - script CronLord from CI, Terraform, or your own tools.
- [Deployment](deployment.md) - put it behind a reverse proxy.
