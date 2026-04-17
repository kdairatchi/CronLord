# Comparison

CronLord isn't the only way to run cron-with-a-UI. Here's an honest
side-by-side with the three alternatives it most often replaces.

## vs Cronicle

[Cronicle](https://github.com/jhuckaby/Cronicle) is the incumbent.
Node.js server, JSON config, an impressive web UI, multi-server with
manager / worker split.

| | CronLord | Cronicle |
| --- | --- | --- |
| Runtime | Single Crystal binary | Node.js + modules |
| Storage | SQLite (one file) | Local FS or S3-style remote |
| Install | `./cronlord server` | `npm install` + setup.js + config.json |
| Multi-host | Yes (single scheduler + N workers over HMAC) | Yes (master + workers) |
| UI | Server-rendered ECR + htmx | SPA |
| Design tone | Editorial/minimalist | Utilitarian/dashboard |
| License | MIT | MIT |
| Idle RSS | ~15 MB | ~100+ MB |

**Pick CronLord if:** you want one binary, you don't need cross-server
clustering yet, you care about the UI looking like something a human
designed.

**Pick Cronicle if:** you need battle-tested multi-server clustering
today, you have Node.js everywhere anyway, or you need the specific
scheduling primitives it ships (event chains, time windows, shell
plugin catalog).

## vs crontab-ui

[crontab-ui](https://github.com/alseambusher/crontab-ui) edits the
system crontab through a web interface.

| | CronLord | crontab-ui |
| --- | --- | --- |
| Execution | Own scheduler, own process | Hands off to system `cron` |
| Job types | `shell`, `http`, `claude` | `shell` only (whatever `cron` runs) |
| Logs | SSE tail, per-run, in UI | File paths you configure |
| State | SQLite | System crontab file |
| Runtime | Crystal binary | Node.js |
| Multi-host | HMAC protocol ready | No (each host edits its own crontab) |

**Pick CronLord if:** you want unified job metadata, run history,
real-time log streaming, and webhook notifications without glueing
four tools together.

**Pick crontab-ui if:** you specifically need to keep the system
crontab as the source of truth (e.g. policy), or you want changes to
persist even when the UI process is dead.

## vs plain cron

| | CronLord | vixie-cron |
| --- | --- | --- |
| UI | Yes | No |
| Run history | Every run persisted | Only what you log |
| On-failure alerts | Webhook notifier, retries | You wire it up |
| Remote control | REST API | None |
| Edits without sudo | Yes (UI or API) | No (crontab -e) |
| Restart safety | Scheduler reboots, catches up | cron does fine too |
| Resource footprint | ~15 MB | ~1 MB |

**Pick CronLord if:** you've hit the point where you're writing
wrappers around `cron` to capture output, alert on failures, or give
teammates visibility.

**Pick plain cron if:** you have three jobs, they're all `rsync`, and
you never want to think about it again. That's a legitimate choice.

## vs Airflow / Prefect / Dagster

These are orchestrators with DAGs, data lineage, and compute resource
management. Different product category.

| | CronLord | Airflow |
| --- | --- | --- |
| Model | Independent scheduled jobs | DAGs of dependent tasks |
| Runtime | One binary | Python + Postgres + Celery + Redis + web |
| UI | Minimal | Extensive |
| Use case | "run this every 5 min" | "run the ETL pipeline, fan out per customer, retry per task" |

**Pick CronLord** when your jobs are independent scheduled operations.
**Pick Airflow / Prefect / Dagster** when the shape is a DAG with
task-level retry, resource pooling, and cross-task data dependencies.

## vs GitHub Actions (scheduled workflows)

| | CronLord | GHA schedule |
| --- | --- | --- |
| Runs on | Your infra | GitHub runners |
| Latency | Tickless, fires on time | Delayed under load (sometimes minutes) |
| State persistence | SQLite | Workflow logs only |
| Secrets | Env / TOML / your infra | GitHub Secrets |
| Cost | Your infra cost | Free tier → $ under load |

**Pick CronLord** for ops-y jobs that need on-time execution on your
own boxes. **Pick GHA schedule** for CI/CD tasks that need to run in
the context of a repo (linting, link checks, scheduled deploys from
main).

## When not to use CronLord

- You need multi-region active/active today. (v0.1 is single-node.)
- You need DAG semantics. Use an orchestrator.
- You can't run a custom binary. Use GHA / Cronicle-in-Docker / cron.
- Your environment already has Cronicle/Airflow and your pain isn't
  large enough to justify a second scheduler.

## Migration

### From crontab-ui

```sh
crontab -l > current.cron
# For each entry, call POST /api/jobs
```

### From Cronicle

Cronicle exports jobs as JSON. Map the fields to the CronLord schema
(`schedule`, `command`, `kind = "shell" | "http"`). The webhook
notifier covers most of Cronicle's email alerting use cases.

### From plain cron

Paste the crontab entry into the `schedule` + `command` fields in the
UI. That's the whole migration.
