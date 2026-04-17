# GitHub Actions for CronLord

Two workflows keep the project green and ship binaries.

## ci.yml

Runs on every push to `main` (and any `sprint-*` branch) and on pull requests.

- Boots the official `crystallang/crystal:1.19.1` container.
- Installs `libsqlite3-dev` for crystal-sqlite3 linking.
- Restores cached `lib/` and `~/.cache/crystal` keyed on `shard.lock`.
- `shards install` → `crystal spec --order=random` → `crystal build src/cronlord/main.cr`.
- Runs Ameba as an advisory step (non-blocking).

A failing spec or build breaks CI; Ameba findings do not.

## release.yml

Runs on tags that match `v*` (for example `v0.2.1`).

- Builds a fully static Linux binary for `amd64` and `arm64` via Docker Buildx
  (`Dockerfile.release`, Alpine + Crystal 1.19). arm64 uses QEMU.
- Packages each binary together with the views, public CSS, and migrations into
  `cronlord-linux-<arch>.tar.gz`, then computes a companion `.sha256`.
- Publishes everything to a new GitHub release via `softprops/action-gh-release@v2`
  with auto-generated release notes.

Tarball names are chosen to match `scripts/install.sh`, which fetches from
`https://github.com/kdairatchi/CronLord/releases/download/<tag>/cronlord-<arch>.tar.gz`.

## dependabot.yml

Weekly bump of the GitHub Actions versions used by the workflows.
