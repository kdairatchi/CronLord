-- Worker lease columns for the distributed executor protocol.
--
-- jobs.executor      — "local" keeps in-process behavior; "worker" means
--                       the scheduler only writes the run row and leaves
--                       execution to a remote worker that polls /lease.
-- jobs.labels_json   — job-side label requirements. A worker must advertise
--                       at least one overlapping label to lease the job.
--                       Empty array means any worker can take it.
-- runs.worker_id     — which worker is currently holding this run.
-- runs.lease_expires_at — unix timestamp; server re-queues the run after.
-- runs.heartbeat_at  — last heartbeat from the worker, for staleness checks.

ALTER TABLE jobs ADD COLUMN executor   TEXT NOT NULL DEFAULT 'local';
ALTER TABLE jobs ADD COLUMN labels_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE runs ADD COLUMN worker_id         TEXT;
ALTER TABLE runs ADD COLUMN lease_expires_at  INTEGER;
ALTER TABLE runs ADD COLUMN heartbeat_at      INTEGER;

CREATE INDEX IF NOT EXISTS idx_runs_queued_worker
  ON runs(status, worker_id)
  WHERE status = 'queued';
