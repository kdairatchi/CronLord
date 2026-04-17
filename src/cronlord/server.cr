require "kemal"
require "json"
require "ecr"

module CronLord
  # HTTP + WebSocket + server-rendered UI. The UI is intentionally simple —
  # server-rendered ECR + htmx — so that CronLord boots anywhere a single
  # binary can run, without a JS build step.
  class Server
    include ViewHelpers

    getter config : Config
    getter scheduler : Scheduler

    def initialize(@config : Config, @scheduler : Scheduler)
    end

    def start
      configure_kemal
      install_api_routes
      install_html_routes
      Kemal.config.host_binding = @config.listen_host
      Kemal.config.port = @config.listen_port
      STDERR.puts "[server] http://#{@config.listen_host}:#{@config.listen_port}"
      Kemal.run
    end

    private def configure_kemal
      Kemal.config.shutdown_message = false
      Kemal.config.logging = false
      Kemal.config.public_folder = "public"
    end

    # ---------------------------------------------------------------- API ---

    private def install_api_routes
      cfg = @config
      sched = @scheduler

      get "/healthz" do |env|
        env.response.content_type = "application/json"
        {"status" => "ok", "version" => CronLord::VERSION}.to_json
      end

      get "/api/version" do |env|
        env.response.content_type = "application/json"
        {"version" => CronLord::VERSION}.to_json
      end

      get "/api/jobs" do |env|
        next unless require_token(env, cfg)
        env.response.content_type = "application/json"
        Job.all.to_json
      end

      get "/api/jobs/:id" do |env|
        next unless require_token(env, cfg)
        job = Job.find(env.params.url["id"])
        if job.nil?
          env.response.status_code = 404
          next({"error" => "not_found"}.to_json)
        end
        env.response.content_type = "application/json"
        job.to_json
      end

      post "/api/jobs" do |env|
        next unless require_token(env, cfg)
        payload = parse_body(env)
        next unless payload
        job = build_job(payload)
        unless job
          env.response.status_code = 400
          next({"error" => "missing id/name/schedule/command"}.to_json)
        end
        job.upsert
        sched.kick
        env.response.content_type = "application/json"
        env.response.status_code = 201
        job.to_json
      end

      post "/api/jobs/:id/run" do |env|
        next unless require_token(env, cfg)
        job = Job.find(env.params.url["id"])
        if job.nil?
          env.response.status_code = 404
          next({"error" => "not_found"}.to_json)
        end
        run = sched.trigger_now(job, trigger: "api")
        env.response.content_type = "application/json"
        env.response.status_code = 202
        run.to_json
      end

      delete "/api/jobs/:id" do |env|
        next unless require_token(env, cfg)
        deleted = Job.delete(env.params.url["id"])
        sched.kick if deleted
        env.response.content_type = "application/json"
        {"deleted" => deleted}.to_json
      end

      get "/api/runs" do |env|
        next unless require_token(env, cfg)
        env.response.content_type = "application/json"
        Run.recent(
          job_id: env.params.query["job_id"]?,
          limit: env.params.query["limit"]?.try(&.to_i32) || 100,
        ).to_json
      end

      # SSE log tail; simple, proxy-friendly, works without extra JS libs.
      get "/api/runs/:id/log" do |env|
        next unless require_token(env, cfg)
        run = Run.recent(limit: 1000).find { |r| r.id == env.params.url["id"] }
        if run.nil?
          env.response.status_code = 404
          next "not_found"
        end
        stream_log(env, run)
      end

      # Cron explain — powers the live preview in the job editor.
      get "/api/cron/explain" do |env|
        env.response.content_type = "application/json"
        expr = env.params.query["expr"]? || ""
        begin
          cron = Cron.parse(expr)
          fires = cron.next_n(3)
          {
            "ok"       => true,
            "describe" => cron.describe,
            "next"     => fires.first?.try(&.to_s("%Y-%m-%d %H:%M UTC")) || "—",
            "fires"    => fires.map(&.to_s("%Y-%m-%d %H:%M UTC")),
          }.to_json
        rescue ex : Cron::ParseError
          env.response.status_code = 400
          {"ok" => false, "error" => ex.message}.to_json
        end
      end
    end

    # --------------------------------------------------------------- HTML ---

    private def install_html_routes
      cfg = @config
      sched = @scheduler
      server = self

      get "/" do |env|
        page_title = "Overview"
        nav_active = "overview"
        show_new_job = true
        theme = "light"

        jobs = Job.all
        enabled_count = jobs.count(&.enabled)
        all_runs = Run.recent(limit: 300)
        running_count = all_runs.count { |r| r.status == "running" }
        cutoff = (Time.utc - 24.hours).to_unix
        last_day = all_runs.select { |r| (r.started_at || 0) >= cutoff }
        runs_24h = last_day.size
        fails = last_day.count { |r| ["fail", "timeout"].includes?(r.status) }
        fail_rate = last_day.empty? ? "0%" : "#{(100.0 * fails / last_day.size).round(1)}%"

        next_fires = [] of Tuple(Time, Job)
        now = Time.utc
        jobs.select(&.enabled).each do |j|
          begin
            t = Cron.parse(j.schedule).next_after(now)
            next_fires << {t, j} if t
          rescue Cron::ParseError
          end
        end
        next_fires = next_fires.sort_by(&.[0]).first(8)

        job_by_id = jobs.each_with_object({} of String => Job) { |j, h| h[j.id] = j }
        recent_runs = all_runs.first(10).map { |r|
          name = job_by_id[r.job_id]?.try(&.name) || r.job_id
          {r, name}
        }

        status_class = ->(s : String) { ViewHelpers.status_class(s) }

        render "src/cronlord/views/overview.ecr", "src/cronlord/views/layout.ecr"
      end

      get "/jobs" do |env|
        page_title = "Jobs"
        nav_active = "jobs"
        show_new_job = true
        theme = "light"

        now = Time.utc
        raw = Job.all.sort_by { |j| {j.enabled ? 0 : 1, j.name.downcase} }
        jobs = raw.map do |j|
          nxt = begin
            Cron.parse(j.schedule).next_after(now)
          rescue Cron::ParseError
            nil
          end
          {j, nxt}
        end

        render "src/cronlord/views/jobs_index.ecr", "src/cronlord/views/layout.ecr"
      end

      get "/jobs/new" do |env|
        page_title = "New job"
        nav_active = "jobs"
        show_new_job = false
        theme = "light"
        is_new = true
        job = Job.new(Job.new_id, "", "shell", "*/5 * * * *", "echo hello")
        form_action = "/jobs"
        schedule_description = Cron.parse(job.schedule).describe
        schedule_next = Cron.parse(job.schedule).next_after(Time.utc).try(&.to_s("%F %H:%M UTC")) || "—"
        recent_runs = [] of Run
        status_class = ->(s : String) { ViewHelpers.status_class(s) }
        webhook_url = job.args["webhook_url"]?.try(&.as_s?) || ""
        render "src/cronlord/views/job_edit.ecr", "src/cronlord/views/layout.ecr"
      end

      get "/jobs/:id" do |env|
        job = Job.find(env.params.url["id"])
        if job.nil?
          env.response.status_code = 404
          next "Not found"
        end
        page_title = job.name
        nav_active = "jobs"
        show_new_job = false
        theme = "light"
        is_new = false
        form_action = "/jobs/#{job.id}"
        schedule_description = (Cron.parse(job.schedule).describe rescue job.schedule)
        schedule_next = (Cron.parse(job.schedule).next_after(Time.utc).try(&.to_s("%F %H:%M UTC")) rescue nil) || "—"
        recent_runs = Run.recent(job_id: job.id, limit: 15)
        status_class = ->(s : String) { ViewHelpers.status_class(s) }
        webhook_url = job.args["webhook_url"]?.try(&.as_s?) || ""
        render "src/cronlord/views/job_edit.ecr", "src/cronlord/views/layout.ecr"
      end

      post "/jobs" do |env|
        form = env.params.body
        job = job_from_form(form)
        job.upsert
        sched.kick
        env.redirect "/jobs/#{job.id}"
      end

      post "/jobs/:id" do |env|
        existing = Job.find(env.params.url["id"])
        unless existing
          env.response.status_code = 404
          next "Not found"
        end
        form = env.params.body
        job = job_from_form(form, base: existing)
        job.upsert
        sched.kick
        env.redirect "/jobs/#{job.id}"
      end

      post "/jobs/:id/run" do |env|
        job = Job.find(env.params.url["id"])
        if job.nil?
          env.response.status_code = 404
          next "Not found"
        end
        run = sched.trigger_now(job, trigger: "ui")
        env.redirect "/runs/#{run.id}"
      end

      post "/jobs/:id/delete" do |env|
        Job.delete(env.params.url["id"])
        sched.kick
        env.redirect "/jobs"
      end

      get "/runs" do |env|
        page_title = "Runs"
        nav_active = "runs"
        show_new_job = false
        theme = "light"

        status_filter = env.params.query["status"]?.presence
        job_filter = env.params.query["job_id"]?.presence
        runs = Run.recent(job_id: job_filter, limit: 200)
        runs = runs.select { |r| r.status == status_filter } if status_filter

        jobs = Job.all.sort_by(&.name.downcase)
        job_names = jobs.each_with_object({} of String => String) { |j, h| h[j.id] = j.name }

        status_class = ->(s : String) { ViewHelpers.status_class(s) }
        duration_for = ->(r : Run) { ViewHelpers.duration_for(r) }

        render "src/cronlord/views/runs_index.ecr", "src/cronlord/views/layout.ecr"
      end

      get "/runs/:id" do |env|
        run = find_run(env.params.url["id"])
        if run.nil?
          env.response.status_code = 404
          next "Not found"
        end
        job = Job.find(run.job_id)
        job_name = job.try(&.name) || run.job_id
        page_title = "Run · #{job_name}"
        nav_active = "runs"
        show_new_job = false
        theme = "light"
        duration = ViewHelpers.duration_for(run)
        status_class = ->(s : String) { ViewHelpers.status_class(s) }
        initial_log = File.exists?(run.log_path) ? File.read(run.log_path) : ""
        render "src/cronlord/views/run_show.ecr", "src/cronlord/views/layout.ecr"
      end

      get "/settings" do |env|
        page_title = "Settings"
        nav_active = "settings"
        show_new_job = false
        theme = "light"
        render "src/cronlord/views/settings.ecr", "src/cronlord/views/layout.ecr"
      end
    end

    # ------------------------------------------------------------ helpers ---

    private def stream_log(env, run : Run)
      env.response.content_type = "text/event-stream"
      env.response.headers["Cache-Control"] = "no-cache"
      env.response.headers["X-Accel-Buffering"] = "no"
      io = env.response
      if File.exists?(run.log_path)
        File.open(run.log_path, "r") do |f|
          f.each_line { |line| io.puts "data: #{line}"; io.puts }
          io.flush
        end
      end
      io.puts "event: end"
      io.puts "data: #{run.status}"
      io.puts
      io.flush
    end

    private def require_token(env, cfg : Config) : Bool
      return true if cfg.admin_token.nil?
      presented = env.request.headers["Authorization"]?.try(&.sub(/^Bearer\s+/i, ""))
      presented ||= env.params.query["token"]?
      if presented == cfg.admin_token
        true
      else
        env.response.status_code = 401
        env.response.content_type = "application/json"
        env.response.print({"error" => "unauthorized"}.to_json)
        false
      end
    end

    private def parse_body(env) : Hash(String, JSON::Any)?
      body = env.request.body.try(&.gets_to_end) || ""
      JSON.parse(body).as_h
    rescue
      env.response.status_code = 400
      env.response.content_type = "application/json"
      env.response.print({"error" => "invalid JSON"}.to_json)
      nil
    end

    private def build_job(h : Hash(String, JSON::Any)) : Job?
      id = h["id"]?.try(&.as_s?) || Job.new_id
      name = h["name"]?.try(&.as_s?) || id
      schedule = h["schedule"]?.try(&.as_s?)
      command = h["command"]?.try(&.as_s?)
      return nil unless schedule && command
      kind = h["kind"]?.try(&.as_s?) || "shell"
      job = Job.new(id, name, kind, schedule, command)
      job.description = h["description"]?.try(&.as_s?) || ""
      job.category = h["category"]?.try(&.as_s?) || "default"
      job.timezone = h["timezone"]?.try(&.as_s?) || "UTC"
      job.timeout_sec = h["timeout_sec"]?.try(&.as_i?) || 0
      job.max_concurrent = h["max_concurrent"]?.try(&.as_i?) || 1
      enabled_any = h["enabled"]?
      job.enabled = enabled_any.nil? || (enabled_any.as_bool? != false)
      if env_any = h["env"]?
        env_any.as_h.each { |k, v| job.env[k] = v.as_s? || v.to_s }
      end
      job.source = h["source"]?.try(&.as_s?) || "api"
      job
    end

    private def job_from_form(form : HTTP::Params, base : Job? = nil) : Job
      id = form["id"]?.presence || base.try(&.id) || Job.new_id
      name = form["name"]?.presence || id
      kind = form["kind"]?.presence || "shell"
      schedule = form["schedule"]?.presence || "*/5 * * * *"
      command = form["command"]?.presence || ""
      job = base || Job.new(id, name, kind, schedule, command)
      job.id = id if base.nil?
      job.name = name
      job.kind = kind
      job.schedule = schedule
      job.command = command
      job.description = form["description"]? || ""
      job.category = form["category"]?.presence || "default"
      job.timezone = form["timezone"]?.presence || "UTC"
      job.timeout_sec = form["timeout_sec"]?.try(&.to_i32?) || 0
      job.max_concurrent = form["max_concurrent"]?.try(&.to_i32?) || 1
      job.retry_count = form["retry_count"]?.try(&.to_i32?) || 0
      job.enabled = form["enabled"]? != "0"
      job.source = base.try(&.source) || "api"
      webhook = form["webhook_url"]?.try(&.strip)
      if webhook && !webhook.empty?
        job.args["webhook_url"] = JSON::Any.new(webhook)
      else
        job.args.delete("webhook_url")
      end
      job.working_dir = form["working_dir"]?.presence
      job
    end

    private def find_run(id : String) : Run?
      Run.recent(limit: 2000).find { |r| r.id == id }
    end
  end
end
