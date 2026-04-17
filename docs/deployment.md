# Deployment

CronLord wants to be boring to run: one binary, one SQLite file, one
log directory. This page covers the setups that actually show up in
production.

## Single-host Docker

Fast to stand up, trivial to upgrade.

```yaml
# docker-compose.yml
services:
  cronlord:
    image: cronlord:latest
    restart: unless-stopped
    ports: ["7070:7070"]
    environment:
      CRONLORD_ADMIN_TOKEN: "${CRONLORD_ADMIN_TOKEN}"
    volumes:
      - cronlord-data:/var/lib/cronlord
      - ./cronlord.toml:/app/cronlord.toml:ro
volumes:
  cronlord-data:
```

Upgrade path:

```sh
docker compose pull && docker compose up -d
```

SQLite WAL survives container restarts cleanly. The data volume is the
only thing you ever need to back up.

## systemd (bare metal)

Either use `scripts/install.sh` or drop `contrib/cronlord.service`
manually. The unit is hardened by default:

- `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`
- `CapabilityBoundingSet=` (empty — no kernel capabilities)
- `SystemCallFilter=@system-service` minus `@privileged @resources`
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`
- `ReadWritePaths=/var/lib/cronlord` only

This is intentionally more locked-down than what most jobs need. If a
`shell` job legitimately needs to write outside `/var/lib/cronlord`,
add the path to `ReadWritePaths` rather than removing protections.

### Upgrade

```sh
systemctl stop cronlord
curl -fsSL https://github.com/kdairatchi/CronLord/releases/latest/download/cronlord-linux-amd64.tar.gz | tar -xz -C /tmp
install -m 0755 /tmp/cronlord /usr/local/bin/cronlord
systemctl start cronlord
```

Migrations run automatically on boot. If a migration fails the scheduler
exits before binding port 7070 — check journalctl.

## Reverse proxy + TLS

CronLord binds HTTP only. Put it behind nginx/Caddy/Traefik for TLS.

### Caddy

```
cron.example.com {
  reverse_proxy 127.0.0.1:7070
}
```

That's it. Caddy fetches certs automatically. The admin token on the
scheduler handles API auth; for the UI add Caddy basic-auth or your
SSO provider.

### nginx

```nginx
server {
  server_name cron.example.com;
  listen 443 ssl http2;

  ssl_certificate     /etc/letsencrypt/live/cron.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/cron.example.com/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:7070;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    # SSE streams for run logs — disable buffering:
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 1h;
  }
}
```

The `proxy_buffering off` is important — without it SSE log tailing
shows nothing until the connection closes.

### Cloudflare Tunnel

```sh
cloudflared tunnel --url http://127.0.0.1:7070
```

Add your Access policy in the Cloudflare dashboard. CronLord doesn't
need to know; it just serves HTTP to the tunnel.

## Backups

Everything lives in `data_dir` (default `/var/lib/cronlord`):

- `cronlord.db` — jobs, runs, audit, tokens, workers.
- `cronlord.db-wal`, `cronlord.db-shm` — WAL + shared memory.
- `logs/<run_id>.log` — per-run stdout/stderr.

A consistent snapshot is as simple as:

```sh
sqlite3 /var/lib/cronlord/cronlord.db ".backup /backup/cronlord-$(date -I).db"
```

Or rsync the whole directory with the service stopped (WAL is safe to
copy while running, but stopping is cleaner for a full snapshot).

## High availability

v0.1 is single-node. Two schedulers against one SQLite file will corrupt
each other — don't do it. If you need HA today, do active/passive with
shared storage (NFS/EBS) and a watchdog that fails over on health check
miss.

Multi-master (via embedded Raft or external Postgres) is on the roadmap.

## Resource sizing

CronLord itself uses ~15 MB RSS idle. The expensive thing is what your
jobs do. Sizing guidance:

- **Dozens of jobs:** any $5/mo VPS.
- **Hundreds of jobs, short runs:** 1 vCPU / 1 GB is fine.
- **Heavy concurrent jobs (long-running shell, large HTTP bodies):** size
  for peak concurrency, not job count. Each concurrent run is a full
  child process with its own pipes.

The scheduler thread is tickless — it only wakes when the next job is
due. Idle CPU is zero.

## Logs

- `stderr` from the scheduler → journalctl/docker logs.
- Per-run job output → `logs/<run_id>.log` in the data dir.

Run logs are not auto-rotated in v0.1. Add a daily `find logs/ -mtime
+30 -delete` in another cron job if disk usage matters.

## Troubleshooting

- **`/healthz` returns 200 but jobs never fire:** check the scheduler
  logs. Almost always a bad cron expression on a recently-added job;
  fix the expression or delete the job.
- **Runs stuck in `running`:** process crashed before `mark_finished`.
  Not yet auto-reaped — manually mark them via
  `UPDATE runs SET status='fail' WHERE status='running' AND started_at < strftime('%s','now','-2 hours')`.
- **SSE log tail blank:** reverse proxy buffering (see nginx snippet).
- **Database locked:** WAL mode with `busy_timeout=5000` should avoid
  this. If you see it, make sure only one scheduler instance is running.
