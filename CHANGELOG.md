# Changelog

All notable changes to CronLord. Dates are in UTC. This project follows
semantic versioning.

## [0.3.3] — 2026-04-18

### Added
- **GHCR publishing.** The release workflow now builds a multi-arch
  (linux/amd64 + linux/arm64) runtime image via `docker buildx` and
  pushes it to `ghcr.io/kdairatchi/cronlord` with `:<version>`,
  `:<minor>`, and `:latest` tags on every `v*` tag.

### Fixed
- `Dockerfile` (runtime image) now installs the `-static`/`-dev`
  variants of sqlite, openssl, pcre2, zlib, and gc, matching the fix
  that landed in `Dockerfile.release` for v0.3.2. Without this a plain
  `docker build .` failed at link time.

### Changed
- README, `docs/index.md`, `docs/getting-started.md`, and
  `docs/deployment.md` now reference `ghcr.io/kdairatchi/cronlord:latest`
  instead of a never-published `cronlord:latest`.

## [0.3.2] — 2026-04-18

### Fixed
- **Release workflow.** `Dockerfile.release` now installs the
  `-static` and `-dev` variants of `sqlite`, `openssl`, `pcre2`, `zlib`,
  and `gc` on the Alpine build image. Without these, `shards build
  --static` failed at link time with `cannot find -lsqlite3`, so the
  v0.3.1 release tarballs were never published.

### Changed
- `README.md` now shows a banner from `public/img/cronlord-banner.png`.

## [0.3.1] — 2026-04-18

### Security
- **Outbound HTTP guard.** All notifier and `http` runner requests now
  route through `CronLord::HttpGuard` — scheme is restricted to
  `http`/`https`, the Slack channel enforces the `https://hooks.slack.com/`
  prefix via a real allowlist, and an opt-in
  `CRONLORD_BLOCK_PRIVATE_NETS=1` resolves the target host and refuses
  RFC1918, loopback, link-local (`169.254/16`), CGNAT (`100.64/10`),
  multicast, and non-global IPv6. Clients are built with explicit
  `host`/`port`/`tls` keyword args instead of `HTTP::Client.new(uri)`.

### Fixed
- Job and run SQL selects are hoisted to named constants and the
  worker-lease query builds its `IN (?,?,…)` clause through a helper
  so every DB call receives a literal SQL string.
- `cronlord worker register` no longer interpolates the plaintext
  secret into a `puts` label line — the value prints on its own line
  after a shown-once notice.

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
