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
- **Timezone-aware schedules.** Each job carries an IANA timezone; cron
  expressions match the wall clock in that zone, with POSIX-correct
  DST behavior (spring-forward gaps are skipped, fall-back repeats fire
  exactly once).
- **Slack notifications.** Point a job at a `https://hooks.slack.com/`
  URL and every finish posts a Block Kit message with status, duration,
  exit code, and the error (when the run failed).

## Get running in 60 seconds

```sh
# Docker
docker run -p 7070:7070 -v cronlord:/var/lib/cronlord \
  ghcr.io/kdairatchi/cronlord:latest

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

v0.3.6 — runs can now be cancelled. `POST /api/runs/:id/cancel` (and a
Cancel button on the run detail page) flips queued runs straight to
`cancelled`, signals `SIGTERM → SIGKILL` on locally-executed shell
runs, and — for worker-leased runs — returns `410 Gone` on the next
heartbeat so the worker aborts its subprocess and reports
`cancelled`. Every cancel writes a `run.cancel` audit row.
v0.3.5 — every pushed GHCR image now carries an attached SPDX SBOM
and SLSA `mode=max` build provenance attestation via
`docker/build-push-action`'s native flags. Ships alongside a new
`SECURITY.md` that documents the supported-versions window,
reporting address, and cosign verify command. No runtime changes.
v0.3.4 — the release workflow now keyless-signs every pushed GHCR
reference with cosign via GitHub OIDC, and the runtime `Dockerfile`
`COPY`s `public/` into the build stage so the docker publish step
actually succeeds. No runtime or API changes.
v0.3.3 — release workflow now publishes a multi-arch image to
`ghcr.io/kdairatchi/cronlord` (`:latest`, `:<version>`, `:<minor>`).
The runtime `Dockerfile` gets the same static-libs fix that landed on
`Dockerfile.release` in v0.3.2. No runtime or API changes.
v0.3.2 — packaging patch over v0.3.1: `Dockerfile.release` installs the
`-static`/`-dev` variants of sqlite, openssl, pcre2, zlib, and gc so
`shards build --static` actually links on Alpine. No runtime changes.
v0.3.1 added outbound-HTTP hardening: Slack/webhook/http-runner calls
route through `HttpGuard`, the Slack prefix is enforced via an
allowlist, and `CRONLORD_BLOCK_PRIVATE_NETS=1` refuses RFC1918,
loopback, link-local, CGNAT, and multicast targets on resolve.
v0.3.0 added per-job IANA timezones with DST-correct firing, the
Slack webhook channel alongside the generic webhook, and GitHub
Actions workflows for CI (spec + build) and release (static
linux-amd64 / linux-arm64 tarballs via Docker Buildx + QEMU).

## License

MIT. See [LICENSE](https://github.com/kdairatchi/CronLord/blob/main/LICENSE).
