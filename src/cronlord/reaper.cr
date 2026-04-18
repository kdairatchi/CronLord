module CronLord
  # Housekeeping for runs and their log files.
  #
  # * On boot, any row still in `running` is from a previous process that
  #   crashed or was killed. Mark it `fail` so the UI stops lying.
  # * A long-lived fiber deletes per-run log files older than `log_ttl_days`.
  #   The run rows themselves are kept for history; only the logs are
  #   pruned. SQLite storage is cheap, a year of log files isn't.
  module Reaper
    extend self

    DEFAULT_LOG_TTL_DAYS = 30

    # Reap zombies from the previous process. Called at startup.
    def reap_zombies!(db = DB.conn) : Int32
      res = db.exec(
        "UPDATE runs SET status=?, finished_at=?, error=? " \
        "WHERE status IN ('running','queued') AND finished_at IS NULL",
        "fail", Time.utc.to_unix, "scheduler restarted before run finished")
      affected = res.rows_affected.to_i32
      STDERR.puts "[reaper] marked #{affected} stuck runs as fail" if affected > 0
      affected
    end

    # Loop forever, sweeping old log files once per day.
    def run_log_reaper(config : Config, ttl_days : Int32 = DEFAULT_LOG_TTL_DAYS) : Nil
      cutoff_seconds = ttl_days.to_i64 * 86_400
      loop do
        begin
          purge_logs(config.log_dir, cutoff_seconds)
        rescue ex
          STDERR.puts "[reaper] log purge failed: #{ex.class}: #{ex.message}"
        end
        sleep 24.hours
      end
    end

    # Any run whose lease_expires_at is in the past and whose status is
    # still 'running' means the worker crashed or partitioned. Put it back
    # in the queue so another worker picks it up. We keep the run row.
    def expire_stale_leases!(db = DB.conn) : Int32
      now = Time.utc.to_unix
      res = db.exec(
        "UPDATE runs SET status='queued', worker_id=NULL, lease_expires_at=NULL, started_at=NULL " \
        "WHERE status='running' AND lease_expires_at IS NOT NULL AND lease_expires_at < ?",
        now)
      affected = res.rows_affected.to_i32
      STDERR.puts "[reaper] re-queued #{affected} expired leases" if affected > 0
      affected
    end

    # Background loop that polls for expired leases.
    def run_lease_reaper(interval : Time::Span = 30.seconds) : Nil
      loop do
        begin
          expire_stale_leases!
        rescue ex
          STDERR.puts "[reaper] lease expire failed: #{ex.class}: #{ex.message}"
        end
        sleep interval
      end
    end

    # Walk the log dir; delete files older than cutoff. Empty directories
    # stay - they're cheap and jobs may create new logs in them.
    def purge_logs(log_dir : String, cutoff_seconds : Int64) : Int32
      return 0 unless Dir.exists?(log_dir)
      deadline = Time.utc - cutoff_seconds.seconds
      removed = 0
      walk(log_dir) do |path|
        next unless path.ends_with?(".log")
        mtime = File.info(path).modification_time
        if mtime < deadline
          File.delete(path)
          removed += 1
        end
      rescue File::NotFoundError
        # Another fiber may have removed it between stat and delete.
      end
      STDERR.puts "[reaper] purged #{removed} old log files" if removed > 0
      removed
    end

    private def walk(dir : String, &block : String ->)
      Dir.each_child(dir) do |name|
        path = File.join(dir, name)
        if File.directory?(path)
          walk(path, &block)
        else
          block.call(path)
        end
      end
    end
  end
end
