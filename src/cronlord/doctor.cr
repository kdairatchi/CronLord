module CronLord
  # Self-check command. Probes the install in under a second and reports
  # what's wrong. Pairs with docs/troubleshooting.md - anything doctor
  # flags should have a fix in that guide.
  module Doctor
    extend self

    enum Status
      OK
      Warn
      Fail
    end

    struct Check
      getter name : String
      getter status : Status
      getter detail : String

      def initialize(@name : String, @status : Status, @detail : String)
      end
    end

    # Run every check, print the report, return an exit code.
    # 0 = all ok, 1 = warnings only, 2 = at least one failure.
    def run(cfg : Config, format : Symbol = :text) : Int32
      checks = collect(cfg)
      case format
      when :json then print_json(checks)
      else            print_text(checks)
      end
      exit_code(checks)
    end

    private def collect(cfg : Config) : Array(Check)
      [
        check_binary,
        check_config(cfg),
        check_data_dir(cfg),
        check_db(cfg),
        check_migrations,
        check_log_dir(cfg),
        check_stuck_runs,
        check_workers,
        check_timezone,
        check_admin_token(cfg),
        check_private_nets,
        check_claude_cli,
      ]
    end

    private def check_binary : Check
      Check.new("binary", Status::OK,
        "cronlord #{CronLord::VERSION} (crystal #{Crystal::VERSION})")
    end

    private def check_config(cfg : Config) : Check
      path = Config::DEFAULT_PATH
      if File.exists?(path)
        Check.new("config", Status::OK, "#{path} loaded")
      else
        Check.new("config", Status::OK, "no #{path} - using env + defaults")
      end
    end

    private def check_data_dir(cfg : Config) : Check
      if !Dir.exists?(cfg.data_dir)
        return Check.new("data_dir", Status::Fail,
          "#{cfg.data_dir} does not exist")
      end
      probe = File.join(cfg.data_dir, ".cronlord-doctor-probe")
      File.write(probe, "ok")
      File.delete(probe)
      Check.new("data_dir", Status::OK, "#{cfg.data_dir} writable")
    rescue ex
      Check.new("data_dir", Status::Fail,
        "#{cfg.data_dir} not writable: #{ex.message}")
    end

    private def check_db(cfg : Config) : Check
      unless File.exists?(cfg.db_path)
        return Check.new("db", Status::Warn,
          "#{cfg.db_path} does not exist yet - run 'cronlord migrate'")
      end
      result = DB.conn.scalar("PRAGMA integrity_check").to_s
      if result == "ok"
        mode = DB.conn.scalar("PRAGMA journal_mode").to_s
        Check.new("db", Status::OK,
          "#{cfg.db_path} integrity_check=ok journal_mode=#{mode}")
      else
        Check.new("db", Status::Fail,
          "integrity_check returned: #{result}")
      end
    rescue ex
      Check.new("db", Status::Fail, "query failed: #{ex.message}")
    end

    private def check_migrations : Check
      applied = [] of Int32
      DB.conn.query_each("SELECT version FROM schema_migrations ORDER BY version") do |rs|
        applied << rs.read(Int32)
      end
      on_disk = Dir.children(DB::MIGRATION_DIR)
        .select(&.ends_with?(".sql"))
        .compact_map(&.[0, 3].to_i?)
        .sort
      pending = on_disk - applied
      if pending.empty?
        Check.new("migrations", Status::OK,
          "#{applied.size} applied, 0 pending")
      else
        Check.new("migrations", Status::Warn,
          "#{pending.size} pending (#{pending.join(", ")}) - run 'cronlord migrate'")
      end
    rescue ex
      Check.new("migrations", Status::Fail, "cannot read schema_migrations: #{ex.message}")
    end

    private def check_log_dir(cfg : Config) : Check
      unless Dir.exists?(cfg.log_dir)
        return Check.new("log_dir", Status::Warn,
          "#{cfg.log_dir} missing - created on first run")
      end
      size = dir_size(cfg.log_dir)
      human = humanize_bytes(size)
      ttl = ENV["CRONLORD_LOG_TTL_DAYS"]?.try(&.to_i32?) || Reaper::DEFAULT_LOG_TTL_DAYS
      if size > 1_073_741_824_i64 # 1 GiB
        Check.new("log_dir", Status::Warn,
          "#{human} in #{cfg.log_dir} - retention=#{ttl}d, consider 'CRONLORD_LOG_TTL_DAYS=7'")
      else
        Check.new("log_dir", Status::OK,
          "#{human} in #{cfg.log_dir} (retention=#{ttl}d)")
      end
    end

    private def check_stuck_runs : Check
      cutoff = Time.utc.to_unix - 86_400 # 24h
      stuck = DB.conn.scalar(
        "SELECT count(*) FROM runs WHERE status='running' AND started_at IS NOT NULL AND started_at < ?",
        cutoff).as(Int64)
      if stuck == 0
        Check.new("stuck_runs", Status::OK, "no runs stuck > 24h in 'running'")
      else
        Check.new("stuck_runs", Status::Warn,
          "#{stuck} run(s) in 'running' older than 24h - restart reaps on boot")
      end
    rescue ex
      Check.new("stuck_runs", Status::Warn, "query failed: #{ex.message}")
    end

    private def check_workers : Check
      workers = Worker.all
      if workers.empty?
        return Check.new("workers", Status::OK,
          "no workers registered (executor=local only)")
      end
      now = Time.utc.to_unix
      stale = workers.count do |w|
        w.enabled && (w.last_seen.nil? || (now - w.last_seen.not_nil!) > 300)
      end
      if stale == 0
        Check.new("workers", Status::OK,
          "#{workers.size} worker(s), all heartbeating within 5m")
      else
        Check.new("workers", Status::Warn,
          "#{stale}/#{workers.size} worker(s) silent > 5m")
      end
    rescue ex
      Check.new("workers", Status::Warn, "Worker.all failed: #{ex.message}")
    end

    private def check_timezone : Check
      Time::Location.load("America/New_York")
      Check.new("timezone", Status::OK, "IANA tzdata available")
    rescue ex
      Check.new("timezone", Status::Fail,
        "tzdata missing - install 'tzdata' package (#{ex.message})")
    end

    private def check_admin_token(cfg : Config) : Check
      if cfg.admin_token.nil? || cfg.admin_token.not_nil!.empty?
        if cfg.listen_host == "127.0.0.1" || cfg.listen_host == "localhost"
          Check.new("admin_token", Status::Warn,
            "unset - OK while bound to #{cfg.listen_host}, required before exposing publicly")
        else
          Check.new("admin_token", Status::Fail,
            "unset and listening on #{cfg.listen_host} - set CRONLORD_ADMIN_TOKEN")
        end
      else
        len = cfg.admin_token.not_nil!.size
        if len < 32
          Check.new("admin_token", Status::Warn,
            "set but short (#{len} chars) - use `openssl rand -hex 32`")
        else
          Check.new("admin_token", Status::OK, "set (#{len} chars)")
        end
      end
    end

    private def check_private_nets : Check
      if ENV["CRONLORD_BLOCK_PRIVATE_NETS"]? == "1"
        Check.new("private_nets_guard", Status::OK,
          "enabled - outbound HTTP blocks RFC1918/loopback/CGNAT")
      else
        Check.new("private_nets_guard", Status::OK,
          "disabled - set CRONLORD_BLOCK_PRIVATE_NETS=1 when exposed to untrusted job authors")
      end
    end

    private def check_claude_cli : Check
      uses_claude = DB.conn.scalar("SELECT count(*) FROM jobs WHERE kind='claude'").as(Int64) > 0
      unless uses_claude
        return Check.new("claude_cli", Status::OK, "no 'claude' jobs - skipped")
      end
      cli = ENV["CRONLORD_CLAUDE_CLI"]? || "claude"
      path = Process.find_executable(cli)
      if path
        Check.new("claude_cli", Status::OK, "found at #{path}")
      else
        Check.new("claude_cli", Status::Fail,
          "'#{cli}' not on PATH but claude-kind jobs exist - install Claude Code CLI or set CRONLORD_CLAUDE_CLI")
      end
    rescue ex
      Check.new("claude_cli", Status::Warn, "check failed: #{ex.message}")
    end

    # --- helpers ---

    private def print_text(checks : Array(Check))
      width = checks.map(&.name.size).max
      checks.each do |c|
        badge = case c.status
                when Status::OK   then "[ ok ]"
                when Status::Warn then "[warn]"
                when Status::Fail then "[fail]"
                end
        puts "#{badge}  %-#{width}s  %s" % [c.name, c.detail]
      end
      ok = checks.count(&.status.==(Status::OK))
      warn = checks.count(&.status.==(Status::Warn))
      fail = checks.count(&.status.==(Status::Fail))
      puts ""
      puts "summary: #{ok} ok, #{warn} warn, #{fail} fail"
    end

    private def print_json(checks : Array(Check))
      rows = checks.map do |c|
        {
          "name"   => c.name,
          "status" => c.status.to_s.downcase,
          "detail" => c.detail,
        }
      end
      puts({"version" => CronLord::VERSION, "checks" => rows}.to_json)
    end

    # Public so specs can exercise the exit-code ladder without mocking STDOUT.
    def exit_code(checks : Array(Check)) : Int32
      return 2 if checks.any?(&.status.==(Status::Fail))
      return 1 if checks.any?(&.status.==(Status::Warn))
      0
    end

    private def dir_size(dir : String) : Int64
      total = 0_i64
      Dir.each_child(dir) do |name|
        path = File.join(dir, name)
        if File.directory?(path)
          total += dir_size(path)
        else
          total += File.info(path).size
        end
      rescue File::NotFoundError
      end
      total
    end

    private def humanize_bytes(n : Int64) : String
      units = %w[B KiB MiB GiB TiB]
      f = n.to_f64
      i = 0
      while f >= 1024 && i < units.size - 1
        f /= 1024
        i += 1
      end
      "%.1f %s" % [f, units[i]]
    end
  end
end
