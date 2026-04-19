---
title: Contributing
nav_order: 10
---

# Contributing to CronLord

Bug reports, specs, doc fixes, and small focused features are welcome.
No new dependencies without opening an issue first - every shard added is a supply-chain surface and that policy is a hard rule.

## Setup

```sh
git clone https://github.com/kdairatchi/CronLord && cd CronLord
shards install
shards build --release        # release binary -> bin/cronlord
crystal spec                  # full test suite
./bin/ameba                   # lint
```

Crystal 1.19 or newer is required. For runtime setup (config, first job, API tokens) see [docs/getting-started.md](getting-started.md).

## Hot paths

| Touching...                    | Start here                                                          |
|------------------------------|---------------------------------------------------------------------|
| scheduling / cron parsing    | `src/cronlord/cron.cr`, `spec/cron_spec.cr`                         |
| job execution                | `src/cronlord/runner/shell.cr`, `runner/http/`, `scheduler.cr`      |
| worker protocol / HMAC       | `src/cronlord/worker*.cr`, `spec/hmac_spec.cr`                      |
| web UI / views               | `src/cronlord/views/*.ecr`, `public/css/*`                          |
| HTTP routes / API            | `src/cronlord/server.cr`                                            |
| persistence / migrations     | `src/cronlord/db.cr`, `db/migrations/`                              |
| run cancellation             | `src/cronlord/runner/cancel_registry.cr`, `spec/run_cancel_spec.cr` |
| config surface               | `src/cronlord/config.cr`, `cronlord.toml.example`                   |

## Commands

```sh
# build
shards install && shards build --release   # release binary -> bin/cronlord
shards build                               # debug (faster iteration)

# run
./bin/cronlord server                      # web UI + API on :7070
./bin/cronlord worker run --url http://... --token ...
./bin/cronlord jobs add "*/5 * * * *" "date -u"

# test
crystal spec                               # all specs
crystal spec spec/cron_spec.cr            # focused
./bin/ameba                                # lint
```

## House rules

- SQLite only. No Postgres or MySQL plumbing. The single-binary promise is non-negotiable.
- `shard.lock` is committed. Pin new deps with `~>` version constraints in `shard.yml`.
- No new shards without an issue first. Comment in the issue with what the shard replaces and why stdlib or existing deps don't cover it.
- Specs are required before merging anything that touches `cron.cr`, `runner/`, `worker*.cr`, or auth. Write the spec, then the code.
- Security-sensitive paths get extra review: HMAC signing/verification, the admin token check, and SSRF guards in `runner/http/`. If your PR touches any of these, call it out explicitly in the description.
- Comments explain *why*, not *what*. `# retry on SIGPIPE` is useful. `# this function executes the job` is noise.
- Views (`*.ecr`) stay small and hand-rolled. No templating layers.

## Commit and PR style

Prefixes in use:

| Prefix              | When to use                                          |
|---------------------|------------------------------------------------------|
| `release:`          | version bump commits (`release: v0.3.6 - short desc`)|
| `fix(scope):`       | bug fix with affected component in parens            |
| `ci:`               | changes to `.github/workflows/` only                 |
| `chore(scope):`     | housekeeping (gitignore, deps, tooling config)        |
| `security(scope):`  | hardening, CVE fixes, supply-chain changes           |
| `scripts:`          | changes to `scripts/` only                           |
| `docs:`             | documentation only                                   |
| `feat(scope):`      | new user-visible behaviour                           |

Keep the summary under 72 characters. No period at the end. For multi-file changes use the narrowest scope that's still accurate.

PRs that touch any file in the hot-paths table above must include a spec (new or updated) - do not mark the PR ready without one.

## Security

Report vulnerabilities privately - do not open a public issue. See [SECURITY.md](../SECURITY.md) for the reporting address and the supported-versions window.
