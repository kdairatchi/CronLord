# Security Policy

## Supported versions

CronLord is pre-1.0 and the `0.3.x` line is the only supported branch.
Security fixes land on `main` and are released as patch versions. Older
minor versions do not receive backports — upgrade to the latest
`0.3.x` to get fixes.

| Version | Supported |
| ------- | --------- |
| `0.3.x` | Yes       |
| `< 0.3` | No        |

## Reporting a vulnerability

Do not open a public issue for security bugs. Send details to
**prowlr@proton.me** with subject line `CronLord security: <short
description>`. If you prefer an encrypted channel, include your PGP
key fingerprint and I'll reply with mine.

Include, to the extent you can:

- The affected version (`cronlord --version` or `GET /healthz`).
- A minimal reproduction — ideally a failing `crystal spec` or a curl
  transcript against a local `cronlord server`.
- The impact you believe this has (RCE, SSRF, auth bypass, stored XSS,
  etc.) and who it affects.
- Any known mitigations.

You'll get an acknowledgement within 72 hours. If you haven't heard
back in that window, assume the email didn't reach me and open a
GitHub Discussion titled "security contact needed" — don't disclose
details there.

## Disclosure timeline

- **Day 0** — report received, acknowledgement sent.
- **Day 1-7** — triage, severity assessment, reproduction.
- **Day 7-30** — fix development and coordinated disclosure planning.
- **Release** — patched version tagged, GHSA advisory published,
  reporter credited (unless they asked to stay anonymous).

If a fix takes materially longer than 30 days I'll tell you why.

## In scope

- The HTTP API and web UI surface under `/api/*` and `/`.
- The worker HMAC protocol under `/api/workers/*`.
- The scheduler, runners (`shell`, `http`, `claude`), and the
  notifier — specifically SSRF, command injection, path traversal,
  signature-bypass, and auth issues.
- The systemd unit in `contrib/` and the Alpine Docker image.
- The `install.sh` installer.

## Out of scope

- Social-engineering attacks against this repository's maintainers.
- DoS via resource exhaustion when the API is unauthenticated and
  exposed to the internet — bind to `127.0.0.1` or require
  `CRONLORD_ADMIN_TOKEN` before reporting this class of bug.
- Attacks that require root on the host CronLord runs on.
- Issues in third-party runners you wire up yourself (e.g. pointing
  an `http` job at an internal admin endpoint and then calling that a
  CronLord bug).

## Supply-chain verification

Every release image is keyless-signed with cosign via GitHub OIDC.
Before running a pulled image, verify the signature:

```sh
cosign verify ghcr.io/kdairatchi/cronlord:latest \
  --certificate-identity-regexp='https://github.com/kdairatchi/CronLord/\.github/workflows/release\.yml.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
```

Release tarballs ship with `.sha256` sidecar files. `scripts/install.sh`
verifies the hash before extracting. If you build your own deployment
pipeline, verify the hash yourself — do not trust the tarball alone.
