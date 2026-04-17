-- Remote workers: nodes that lease jobs from CronLord and report back.
-- v1 is deliberately minimal — identity, HMAC secret, and last-seen signal.
-- Lease/finish endpoints arrive in a later sprint; this table exists so the
-- UI and admin API have a stable place to list and manage workers today.

CREATE TABLE IF NOT EXISTS workers (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  secret_hash  TEXT NOT NULL,                -- sha256 hex of shared secret
  labels_json  TEXT NOT NULL DEFAULT '[]',   -- JSON array of strings
  enabled      INTEGER NOT NULL DEFAULT 1,
  last_seen    INTEGER,
  created_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_workers_enabled ON workers(enabled);
