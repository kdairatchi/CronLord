# CronLord

<p align="center">
  <img src="public/img/cronlord-banner.png" alt="CronLord" width="860">
</p>

[![ci](https://github.com/kdairatchi/CronLord/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kdairatchi/CronLord/actions/workflows/ci.yml)
[![release](https://github.com/kdairatchi/CronLord/actions/workflows/release.yml/badge.svg)](https://github.com/kdairatchi/CronLord/actions/workflows/release.yml)
[![license](https://img.shields.io/github/license/kdairatchi/CronLord)](./LICENSE)

A visual, self-hosted cron scheduler in a single Crystal binary.

One static executable. Web UI, REST API, scheduler, reference worker,
and audit trail in one process. Editorial design, SQLite-backed,
~15 MB resident idle.

## Install

```sh
git clone https://github.com/kdairatchi/CronLord
cd CronLord
shards install
shards build --release
./bin/cronlord server
```

Open <http://localhost:7070>.

## What you get

- Tickless cron scheduler with macro expressions (`@hourly`, `@daily`)
  and per-job IANA timezones (DST-correct).
- Three job kinds: `shell`, `http`, `claude` (prompt -> `claude -p`).
- Remote workers over HMAC-signed HTTP; reference worker in the same
  binary (`cronlord worker run`).
- Cancel queued or running jobs from the UI or `POST /api/runs/:id/cancel`.
- Webhook + Slack notification channels.
- Per-run log capture with SSE tailing.
- REST API, Prometheus `/metrics`, audit trail at `/audit`.
- GHCR image signed with cosign, attached SPDX SBOM and SLSA provenance,
  Trivy-scanned for HIGH/CRITICAL CVEs before signing.
- Release tarballs carry `.sha256` sidecars; `install.sh` verifies before
  installing.

## Documentation

Full docs under [`docs/`](docs/index.md):
[getting started](docs/getting-started.md) |
[job kinds](docs/job-kinds.md) |
[API](docs/api.md) |
[deployment](docs/deployment.md) |
[architecture](docs/architecture.md) |
[comparison](docs/comparison.md) |
[contributing](docs/contributing.md).

## License

MIT
