module CronLord
  # Tickless scheduler: computes the next fire time for each enabled job,
  # sleeps until the earliest, spawns a runner fiber, and reschedules.
  #
  # Design:
  #   - `wakeup` channel is used to reinterrupt the sleep when jobs change.
  #   - Concurrency-per-job is enforced via an in-memory counter (`active`).
  #   - Bad cron expressions are logged and the job is skipped until touched.
  class Scheduler
    getter config : Config

    @active = Hash(String, Int32).new(0)
    @active_mu = Mutex.new
    @wakeup = Channel(Nil).new(1)
    @stop = Channel(Nil).new(1)
    @running = false

    def initialize(@config : Config)
    end

    def kick
      select
      when @wakeup.send(nil)
        # queued
      else
        # already pending
      end
    end

    def stop
      @running = false
      select
      when @stop.send(nil)
      else
      end
    end

    def run
      @running = true
      STDERR.puts "[scheduler] started"
      while @running
        jobs = Job.all.select(&.enabled)
        now = Time.utc
        next_fire : Time? = nil
        plan = [] of {Job, Time}

        jobs.each do |job|
          cron = Cron.parse(job.schedule)
          fire = cron.next_after(now)
          next unless fire
          plan << {job, fire}
          next_fire = fire if next_fire.nil? || fire < next_fire
        rescue ex : Cron::ParseError
          STDERR.puts "[scheduler] invalid cron for job #{job.id}: #{ex.message}"
        end

        if next_fire.nil?
          wait(30.seconds)
          next
        end

        delay = next_fire - Time.utc
        if delay.total_seconds > 0
          interrupted = wait(delay)
          next if interrupted
        end

        fire_moment = next_fire
        plan.each do |(job, fire)|
          next unless fire <= fire_moment + 1.second
          dispatch(job)
        end
      end
      STDERR.puts "[scheduler] stopped"
    end

    # Force a run right now, regardless of schedule. Returns the new Run id.
    def trigger_now(job : Job, trigger : String = "manual") : Run
      log_path = run_log_path(job)
      run = Run.create(job.id, log_path, trigger: trigger)
      spawn execute(job, run)
      run
    end

    private def dispatch(job : Job)
      active = @active_mu.synchronize { @active[job.id] }
      if active >= job.max_concurrent
        STDERR.puts "[scheduler] skip #{job.id} (concurrency #{active}/#{job.max_concurrent})"
        return
      end
      log_path = run_log_path(job)
      run = Run.create(job.id, log_path, trigger: "schedule")
      spawn execute(job, run)
    end

    private def execute(job : Job, run : Run)
      @active_mu.synchronize { @active[job.id] += 1 }
      run.mark_started
      buffer = LogBuffer.new(run.log_path)
      begin
        case job.kind
        when "shell"
          Runner::Shell.run(job, run, buffer)
        else
          buffer.write("unsupported job kind '#{job.kind}' — v1 ships shell only", :meta)
          run.mark_finished("fail", 127, "unsupported kind #{job.kind}")
        end
      rescue ex
        buffer.write("[runner error] #{ex.class}: #{ex.message}", :meta) rescue nil
        run.mark_finished("fail", nil, ex.message)
      ensure
        buffer.close rescue nil
        @active_mu.synchronize { @active[job.id] -= 1 }
      end
    end

    private def run_log_path(job : Job) : String
      stamp = Time.utc.to_s("%Y%m%d")
      dir = File.join(@config.log_dir, job.id, stamp)
      Dir.mkdir_p(dir)
      File.join(dir, "#{Time.utc.to_unix_ms}-#{Run.new_id[0, 8]}.log")
    end

    # Returns true if the wait was interrupted by `kick` (jobs changed).
    private def wait(duration : Time::Span) : Bool
      select
      when @wakeup.receive
        true
      when @stop.receive
        @running = false
        false
      when timeout(duration)
        false
      end
    end
  end
end
