module CronLord
  # Prometheus text-format exposition. Zero dependencies - we just build the
  # string each scrape. If /metrics ever becomes hot enough for that to
  # matter, memoize with a ttl cache.
  module Metrics
    extend self

    def render(scheduler : Scheduler) : String
      jobs = Job.all
      runs = Run.recent(limit: 10_000)
      now = Time.utc.to_unix

      enabled = jobs.count(&.enabled)
      disabled = jobs.size - enabled

      status_counts = Hash(String, Int32).new(0)
      runs.each { |r| status_counts[r.status] += 1 }

      last_finish = runs.compact_map(&.finished_at).max? || 0_i64
      age_sec = last_finish.zero? ? 0_i64 : now - last_finish

      running = runs.count { |r| r.status == "running" }

      String.build do |io|
        comment(io, "# HELP cronlord_jobs_total Total jobs registered")
        comment(io, "# TYPE cronlord_jobs_total gauge")
        io << "cronlord_jobs_total " << jobs.size << '\n'

        comment(io, "# HELP cronlord_jobs_enabled Jobs currently enabled")
        comment(io, "# TYPE cronlord_jobs_enabled gauge")
        io << "cronlord_jobs_enabled " << enabled << '\n'

        comment(io, "# HELP cronlord_jobs_disabled Jobs currently paused")
        comment(io, "# TYPE cronlord_jobs_disabled gauge")
        io << "cronlord_jobs_disabled " << disabled << '\n'

        comment(io, "# HELP cronlord_runs_total Runs in the last 10k-row window, labeled by status")
        comment(io, "# TYPE cronlord_runs_total counter")
        %w(queued running success fail timeout cancelled).each do |s|
          io << %(cronlord_runs_total{status=") << s << %("} ) << status_counts[s] << '\n'
        end

        comment(io, "# HELP cronlord_runs_running Currently running runs")
        comment(io, "# TYPE cronlord_runs_running gauge")
        io << "cronlord_runs_running " << running << '\n'

        comment(io, "# HELP cronlord_last_finish_age_seconds Seconds since the most recent run finished")
        comment(io, "# TYPE cronlord_last_finish_age_seconds gauge")
        io << "cronlord_last_finish_age_seconds " << age_sec << '\n'

        comment(io, "# HELP cronlord_build_info Version and build metadata")
        comment(io, "# TYPE cronlord_build_info gauge")
        io << %(cronlord_build_info{version=") << CronLord::VERSION << %("} 1) << '\n'
      end
    end

    private def comment(io, text : String)
      io << text << '\n'
    end
  end
end
