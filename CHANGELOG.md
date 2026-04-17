# Changelog

All notable changes to CronLord. Dates are in UTC. This project follows
semantic versioning.

## [0.3.0] — 2026-04-17

### Added
- **Timezone-aware scheduling.** `Cron#next_after` now accepts a
  `Time::Location` and matches cron fields against the wall clock in
  that zone. Per-job `timezone` is validated at save time. POSIX-cron
  DST semantics: spring-forward gaps don't fire, fall-back repeats
  fire exactly once.
- **Slack webhook channel.** Each job can set
  `args.slack_webhook_url` (must start with `https://hooks.slack.com/`)
  to post a Block Kit message with status, trigger, duration, exit
  code, and the error on failed runs. Status is shown as a text tag
  (`[ok]`/`[fail]`/`[timeout]`/`[cancelled]`) — no emoji.
- **GitHub Actions.** `.github/workflows/ci.yml` runs `crystal spec`
  and a debug build on every push and PR; `release.yml` tags build
  static `linux-amd64` + `linux-arm64` tarballs via Buildx + QEMU
  and publish them through `softprops/action-gh-release@v2` with
  auto-generated notes and SHA256 sums. `dependabot.yml` keeps the
  workflow actions up to date weekly.

### Changed
- `/api/cron/explain` accepts an optional `tz` query parameter and
  renders `next` / `fires` in that zone. Returns `400` on an unknown
  zone.
- Overview and jobs index next-fire columns display in each job's
  configured timezone instead of UTC.
- Job editor live cron preview re-queries whenever the Timezone field
  changes.
- `Notifier.deliver` now dispatches two best-effort fibers
  (generic webhook + Slack) instead of one.

### Fixed
- Scheduler no longer loops forever on a job with an invalid
  timezone — the job is skipped and the error is logged.

## [0.2.0] — 2026-04-17

### Added
- Worker lease / heartbeat / finish protocol over HMAC-signed HTTP.
- Reference worker shipped inside the same binary (`cronlord worker run`).
- `/workers` HTML UI for registration, state, enable / disable, delete.
- Lease reaper re-queues runs whose lease expired.
- Prometheus metrics at `/metrics`.
- Audit trail with HTML index at `/audit`.
- Static linux-amd64 + linux-arm64 Docker image.

### Changed
- Scheduler splits local vs. remote (`executor = "worker"`) execution.

## [0.1.0] — 2026-03-20

Initial scheduler, SQLite persistence, web UI, JSON API, SSE logs,
generic webhook notifier, `shell` + `http` + `claude` runners.
