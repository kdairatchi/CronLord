-- CronLord initial schema.
-- Idempotent via IF NOT EXISTS; migration runner records applied versions.

CREATE TABLE IF NOT EXISTS schema_migrations (
  version    INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS jobs (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  description     TEXT NOT NULL DEFAULT '',
  category        TEXT NOT NULL DEFAULT 'default',
  kind            TEXT NOT NULL,                    -- shell | http | claude (v1)
  schedule        TEXT NOT NULL,                    -- cron expression
  timezone        TEXT NOT NULL DEFAULT 'UTC',
  command         TEXT NOT NULL,                    -- shell: script; http: URL; claude: prompt
  args_json       TEXT NOT NULL DEFAULT '{}',       -- kind-specific options
  env_json        TEXT NOT NULL DEFAULT '{}',
  working_dir     TEXT,
  timeout_sec     INTEGER NOT NULL DEFAULT 0,       -- 0 = no timeout
  max_concurrent  INTEGER NOT NULL DEFAULT 1,
  retry_count     INTEGER NOT NULL DEFAULT 0,
  retry_delay_sec INTEGER NOT NULL DEFAULT 30,
  enabled         INTEGER NOT NULL DEFAULT 1,
  source          TEXT NOT NULL DEFAULT 'api',      -- api | toml
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_jobs_enabled ON jobs(enabled);

CREATE TABLE IF NOT EXISTS runs (
  id            TEXT PRIMARY KEY,
  job_id        TEXT NOT NULL,
  status        TEXT NOT NULL,                      -- queued | running | success | fail | timeout | cancelled
  started_at    INTEGER,
  finished_at   INTEGER,
  exit_code     INTEGER,
  attempt       INTEGER NOT NULL DEFAULT 1,
  log_path      TEXT NOT NULL,
  trigger       TEXT NOT NULL DEFAULT 'schedule',   -- schedule | manual | api
  error         TEXT,
  FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_runs_job_started ON runs(job_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);

CREATE TABLE IF NOT EXISTS tokens (
  id         TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  hash       TEXT NOT NULL UNIQUE,
  role       TEXT NOT NULL DEFAULT 'admin',
  created_at INTEGER NOT NULL,
  last_used  INTEGER
);

CREATE TABLE IF NOT EXISTS audit (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  at         INTEGER NOT NULL,
  actor      TEXT NOT NULL,
  action     TEXT NOT NULL,
  target     TEXT,
  meta_json  TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_audit_at ON audit(at DESC);
