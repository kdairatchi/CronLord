require "option_parser"

module CronLord
  module CLI
    USAGE = <<-U
      cronlord — visual cron scheduler

      commands:
        serve | server             run the scheduler + HTTP API
        migrate                    apply pending SQL migrations
        job list                   list all jobs
        job add --schedule S --command C [--name N] [--id I]
        job rm <id>                delete a job
        job run <id>               trigger a job immediately
        runs [--job ID] [--limit N]
        worker register <name> [--label L]...
        worker list
        worker rm <id>
        worker run --url URL --id ID --key KEY [--name N] [--lease 60] [--poll 5]

      options:
        -c, --config PATH          path to cronlord.toml (default: ./cronlord.toml)
        -h, --help                 show this help

      env:
        CRONLORD_HOST, CRONLORD_PORT, CRONLORD_DATA, CRONLORD_ADMIN_TOKEN
      U

    def self.dispatch(argv : Array(String)) : Int32
      config_path = Config::DEFAULT_PATH

      # Consume our own --config / --help flags from the head of argv, then
      # hand every remaining token to the subcommand untouched. A top-level
      # OptionParser would reject subcommand-specific flags like `--schedule`.
      pre = [] of String
      i = 0
      while i < argv.size
        arg = argv[i]
        case arg
        when "-h", "--help"
          puts USAGE; return 0
        when "-c", "--config"
          config_path = argv[i + 1]? || (STDERR.puts("--config requires a value"); return 2)
          i += 2
          next
        else
          if arg.starts_with?("--config=")
            config_path = arg.split('=', 2)[1]
            i += 1
            next
          end
          pre = argv[i..]
          break
        end
      end

      rest = pre

      if rest.empty?
        puts USAGE
        return 1
      end

      # `worker run` is the only subcommand that runs on a remote host
      # without a scheduler DB — dispatch before opening SQLite.
      if rest.first == "worker" && rest[1]? == "run"
        return cmd_worker_run(rest[2..])
      end

      cfg = Config.load(config_path)
      DB.open(cfg.db_path)
      DB.migrate!(log: false)
      sync_file_jobs(cfg)

      case rest.first
      when "serve", "server" then cmd_serve(cfg)
      when "migrate"         then cmd_migrate(cfg)
      when "job"             then cmd_job(cfg, rest[1..])
      when "runs"            then cmd_runs(rest[1..])
      when "worker"          then cmd_worker(rest[1..])
      else
        STDERR.puts "unknown command: #{rest.first}"
        puts USAGE
        1
      end
    end

    private def self.cmd_worker_run(argv : Array(String)) : Int32
      url = ENV["CRONLORD_URL"]? || ""
      id = ENV["CRONLORD_WORKER_ID"]? || ""
      key = ENV["CRONLORD_HMAC_KEY"]? || ""
      name = ENV["CRONLORD_WORKER_NAME"]? || System.hostname rescue "worker"
      lease_sec = (ENV["CRONLORD_LEASE_SEC"]?.try(&.to_i32?)) || 60
      poll_sec = (ENV["CRONLORD_POLL_SEC"]?.try(&.to_i32?)) || 5

      OptionParser.parse(argv) do |op|
        op.on("--url=URL", "scheduler base URL") { |v| url = v }
        op.on("--id=ID", "worker id") { |v| id = v }
        op.on("--key=KEY", "HMAC key (sha256 of plaintext secret)") { |v| key = v }
        op.on("--name=NAME", "display name (for logs only)") { |v| name = v }
        op.on("--lease=SEC", "lease window seconds (default 60)") { |v| lease_sec = v.to_i32 }
        op.on("--poll=SEC", "idle poll interval (default 5)") { |v| poll_sec = v.to_i32 }
      end

      if url.empty? || id.empty? || key.empty?
        STDERR.puts "usage: cronlord worker run --url URL --id ID --key KEY [--name N] [--lease 60] [--poll 5]"
        STDERR.puts "       env: CRONLORD_URL, CRONLORD_WORKER_ID, CRONLORD_HMAC_KEY"
        return 2
      end

      client = WorkerClient.new(url, id, key)
      loop_ = WorkerLoop.new(client, name, lease_sec, poll_sec)
      Signal::INT.trap { loop_.stop }
      Signal::TERM.trap { loop_.stop }
      loop_.run
      0
    end

    private def self.cmd_serve(cfg : Config) : Int32
      Reaper.reap_zombies!

      scheduler = Scheduler.new(cfg)
      spawn { scheduler.run }
      spawn { Reaper.run_log_reaper(cfg) }
      spawn { Reaper.run_lease_reaper }

      Signal::INT.trap do
        STDERR.puts "\n[cronlord] shutting down"
        scheduler.stop
        Kemal.stop rescue nil
        DB.close
        exit 0
      end

      server = Server.new(cfg, scheduler)
      server.start
      0
    end

    private def self.cmd_worker(argv : Array(String)) : Int32
      case argv.first?
      when "register"
        name = argv[1]?
        unless name
          STDERR.puts "usage: cronlord worker register <name> [--label L]..."
          return 2
        end
        labels = [] of String
        OptionParser.parse(argv[2..]) do |op|
          op.on("--label=L", "add a label (repeatable)") { |v| labels << v }
        end
        worker, plaintext = Worker.register(name, labels: labels)
        puts "id:     #{worker.id}"
        puts "name:   #{worker.name}"
        puts "secret (shown once — copy it now):"
        puts plaintext
        STDERR.puts "note: the value above is not recoverable — store it on the worker host now."
        0
      when "list"
        Worker.all.each do |w|
          seen = w.last_seen ? Time.unix(w.last_seen.not_nil!).to_s("%F %T") : "never"
          puts "%-36s %-24s %-6s %s" % [w.id, w.name, (w.enabled ? "on" : "off"), seen]
        end
        0
      when "rm"
        id = argv[1]?
        unless id
          STDERR.puts "usage: cronlord worker rm <id>"
          return 2
        end
        puts(Worker.delete(id) ? "deleted" : "not_found")
        0
      else
        STDERR.puts "worker subcommands: register <name> | list | rm <id>"
        1
      end
    end

    private def self.cmd_migrate(cfg : Config) : Int32
      DB.migrate!
      puts "ok"
      0
    end

    private def self.cmd_job(cfg : Config, argv : Array(String)) : Int32
      case argv.first?
      when "list" then job_list
      when "add"  then job_add(argv[1..])
      when "rm"   then job_rm(argv[1..])
      when "run"  then job_run_once(cfg, argv[1..])
      else
        STDERR.puts "job subcommands: list | add | rm | run"
        1
      end
    end

    private def self.job_list : Int32
      jobs = Job.all
      if jobs.empty?
        puts "(no jobs)"
      else
        puts "%-36s %-20s %-12s %-6s %s" % ["ID", "NAME", "SCHEDULE", "ON", "COMMAND"]
        jobs.each do |j|
          puts "%-36s %-20s %-12s %-6s %s" % [
            j.id, trunc(j.name, 20), trunc(j.schedule, 12),
            (j.enabled ? "yes" : "no"), trunc(j.command, 60),
          ]
        end
      end
      0
    end

    private def self.job_add(argv : Array(String)) : Int32
      id = nil.as(String?)
      name = nil.as(String?)
      schedule = nil.as(String?)
      command = nil.as(String?)
      timeout = 0
      kind = "shell"

      OptionParser.parse(argv) do |op|
        op.on("--id=ID", "job id") { |v| id = v }
        op.on("--name=NAME", "human name") { |v| name = v }
        op.on("--schedule=CRON", "cron expression") { |v| schedule = v }
        op.on("--command=CMD", "shell command") { |v| command = v }
        op.on("--timeout=SEC", "kill after N seconds") { |v| timeout = v.to_i32 }
        op.on("--kind=KIND", "shell|http|claude") { |v| kind = v }
      end

      sched = schedule
      cmd = command
      unless sched && cmd
        STDERR.puts "--schedule and --command are required"
        return 2
      end

      begin
        Cron.parse(sched)
      rescue ex : Cron::ParseError
        STDERR.puts "invalid cron: #{ex.message}"
        return 2
      end

      job_id = (id || Job.new_id).as(String)
      display = (name || job_id).as(String)
      job = Job.new(job_id, display, kind, sched, cmd)
      job.timeout_sec = timeout
      job.upsert
      puts job_id
      0
    end

    private def self.job_rm(argv : Array(String)) : Int32
      id = argv.first?
      unless id
        STDERR.puts "usage: cronlord job rm <id>"
        return 2
      end
      puts(Job.delete(id) ? "deleted" : "not_found")
      0
    end

    private def self.job_run_once(cfg : Config, argv : Array(String)) : Int32
      id = argv.first?
      unless id
        STDERR.puts "usage: cronlord job run <id>"
        return 2
      end
      job = Job.find(id)
      unless job
        STDERR.puts "not_found"
        return 1
      end
      scheduler = Scheduler.new(cfg)
      run = scheduler.trigger_now(job, trigger: "cli")
      puts run.id
      loop do
        updated = Run.recent(job_id: job.id, limit: 5).find { |r| r.id == run.id }
        break if updated && updated.finished_at
        sleep 500.milliseconds
      end
      0
    end

    private def self.cmd_runs(argv : Array(String)) : Int32
      job_id = nil.as(String?)
      limit = 20
      OptionParser.parse(argv) do |op|
        op.on("--job=ID", "filter by job id") { |v| job_id = v }
        op.on("--limit=N", "max rows") { |v| limit = v.to_i32 }
      end
      runs = Run.recent(job_id: job_id, limit: limit)
      if runs.empty?
        puts "(no runs)"
      else
        puts "%-36s %-36s %-10s %-5s %s" % ["RUN", "JOB", "STATUS", "EXIT", "STARTED"]
        runs.each do |r|
          started = r.started_at ? Time.unix(r.started_at.not_nil!).to_s("%F %T") : "-"
          puts "%-36s %-36s %-10s %-5s %s" % [
            r.id, r.job_id, r.status, r.exit_code.to_s, started,
          ]
        end
      end
      0
    end

    # Reconcile [[jobs]] blocks from cronlord.toml into DB. Idempotent;
    # file-sourced jobs are tagged `source=toml` so UI can show them as managed.
    private def self.sync_file_jobs(cfg : Config)
      cfg.file_jobs.each do |fj|
        job = Job.find(fj.id) || Job.new(fj.id, fj.name, fj.kind, fj.schedule, fj.command)
        job.name = fj.name
        job.kind = fj.kind
        job.schedule = fj.schedule
        job.command = fj.command
        job.enabled = fj.enabled
        job.category = fj.category
        job.timeout_sec = fj.timeout_sec
        job.max_concurrent = fj.max_concurrent
        job.timezone = fj.timezone
        job.source = "toml"
        job.upsert
      end
    end

    private def self.trunc(s : String, n : Int32) : String
      s.size > n ? "#{s[0, n - 1]}…" : s
    end
  end
end
