# CronLord

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

## Features (v0.2.0)

- Tickless scheduler with cron + macro expressions (`@hourly`,
  `@daily`, etc.).
- Three job kinds: `shell`, `http`, `claude` (prompt → `claude -p`).
- Remote workers over HMAC-signed HTTP; reference worker ships in
  the same binary (`cronlord worker run`).
- Per-run log capture with SSE tailing in the browser.
- REST API + Prometheus `/metrics` + audit trail at `/audit`.
- Hardened systemd unit and Alpine Docker image in `contrib/` and
  `Dockerfile`.

## Documentation

Full docs under [`docs/`](docs/index.md):
[getting started](docs/getting-started.md) ·
[job kinds](docs/job-kinds.md) ·
[API](docs/api.md) ·
[deployment](docs/deployment.md) ·
[architecture](docs/architecture.md) ·
[comparison](docs/comparison.md).

## License

MIT
