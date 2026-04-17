# CronLord

A visual, self-hosted cron scheduler in a single Crystal binary.

CronLord is one executable with no runtime dependencies. Drop it on a box,
point a browser at port 7070, and you have a scheduler with a web UI, JSON
API, SSE log tailing, remote workers over HMAC, Prometheus metrics, and
an audit trail.

## Why CronLord

Other schedulers either hide behind a Node stack you have to babysit
(Cronicle, crontab-ui) or live in a YAML file you edit with vim and reload
(plain cron). CronLord is the middle ground:

- **One binary.** `./cronlord server` and you're done. No `npm install`,
  no Python venv, no Ruby bundle.
- **SQLite-backed.** Jobs, runs, and audit rows live in one file. Back it
  up with `cp`. No external database required.
- **Editorial UI.** Warm paper neutrals, no neon, no chrome. Designed so
  an on-call engineer at 3 a.m. can read it.
- **Three job kinds.** `shell`, `http`, and `claude` (prompt → `claude -p`)
  ship in v0.1. Add your own runner with ~100 lines of Crystal.
- **Remote workers.** Register a worker from `/workers/new`, run
  `cronlord worker run` on another host, and jobs with
  `executor = worker` are leased out over HMAC-signed HTTP. Crashed
  workers' leases auto-expire and get re-queued.
- **Prometheus metrics.** `/metrics` exposes job, run, and worker
  counters in standard text format.
- **Audit trail.** Every create, update, delete, and manual run lands in
  the audit table and is visible at `/audit`.

## Get running in 60 seconds

```sh
# Docker
docker run -p 7070:7070 -v cronlord:/var/lib/cronlord cronlord:latest

# Or from source
git clone https://github.com/kdairatchi/CronLord && cd CronLord
shards build cronlord --release
./bin/cronlord server
```

Open `http://localhost:7070`.

## What to read next

- **[Getting Started](getting-started.md)** — install paths, first job,
  webhook wiring.
- **[Job Kinds](job-kinds.md)** — `shell`, `http`, `claude` in detail.
- **[API](api.md)** — full JSON API + HMAC worker protocol reference.
- **[Deployment](deployment.md)** — Docker, systemd, reverse proxies,
  hardening.
- **[Architecture](architecture.md)** — how the scheduler, runners, and
  log buffer fit together.
- **[Comparison](comparison.md)** — CronLord vs Cronicle vs crontab-ui vs
  plain cron.

## Status

v0.2.0 — scheduler core, three job kinds, web UI, REST API, webhook
notifier, audit trail, HMAC worker auth + reference worker,
`/workers` UI, Prometheus metrics, zombie + log + lease reapers.
Ships a single static binary for linux-amd64 and linux-arm64.

## License

MIT. See [LICENSE](https://github.com/kdairatchi/CronLord/blob/main/LICENSE).
