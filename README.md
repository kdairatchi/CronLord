# CronLord

A visual, self-hosted cron scheduler in a single Crystal binary.

One static executable. Web UI, REST API, and scheduler in one process.
Editorial design, SQLite-backed, sub-30 MB resident.

## Install

```sh
# from source (v0.1.0 preview)
git clone https://github.com/kdairatchi/CronLord
cd CronLord
shards install
shards build --release
./bin/cronlord serve
```

Open http://localhost:7070.

## Status

Pre-alpha. Sprint 1: scheduler core + shell runner + SQLite.

## License

MIT
