require "kemal"
require "json"

module CronLord
  # HTTP + WebSocket surface. v0.1 ships a minimal JSON API; the polished UI
  # lands in Sprint 2.
  class Server
    getter config : Config
    getter scheduler : Scheduler

    def initialize(@config : Config, @scheduler : Scheduler)
    end

    def start
      configure_kemal
      install_routes
      Kemal.config.host_binding = @config.listen_host
      Kemal.config.port = @config.listen_port
      STDERR.puts "[server] http://#{@config.listen_host}:#{@config.listen_port}"
      Kemal.run
    end

    private def configure_kemal
      Kemal.config.shutdown_message = false
      Kemal.config.logging = false
    end

    private def install_routes
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
        require_token(env, cfg) || next
        env.response.content_type = "application/json"
        Job.all.to_json
      end

      get "/api/jobs/:id" do |env|
        require_token(env, cfg) || next
        job = Job.find(env.params.url["id"])
        if job.nil?
          env.response.status_code = 404
          next({"error" => "not_found"}.to_json)
        end
        env.response.content_type = "application/json"
        job.to_json
      end

      post "/api/jobs" do |env|
        require_token(env, cfg) || next
        payload = parse_body(env) || next
        job = build_job(payload) || (next bad_request(env, "missing id/name/schedule/command"))
        job.upsert
        sched.kick
        env.response.content_type = "application/json"
        env.response.status_code = 201
        job.to_json
      end

      post "/api/jobs/:id/run" do |env|
        require_token(env, cfg) || next
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
        require_token(env, cfg) || next
        deleted = Job.delete(env.params.url["id"])
        sched.kick if deleted
        env.response.content_type = "application/json"
        {"deleted" => deleted}.to_json
      end

      get "/api/runs" do |env|
        require_token(env, cfg) || next
        env.response.content_type = "application/json"
        Run.recent(
          job_id: env.params.query["job_id"]?,
          limit: env.params.query["limit"]?.try(&.to_i32) || 100,
        ).to_json
      end

      # Tail a run's log as Server-Sent Events; simple and proxy-friendly.
      get "/api/runs/:id/log" do |env|
        require_token(env, cfg) || next
        run = Run.recent(limit: 1000).find { |r| r.id == env.params.url["id"] }
        if run.nil?
          env.response.status_code = 404
          next "not_found"
        end
        tail_log(env, run)
      end
    end

    private def tail_log(env, run : Run)
      env.response.content_type = "text/event-stream"
      env.response.headers["Cache-Control"] = "no-cache"
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
      bad_request(env, "invalid JSON")
      nil
    end

    private def build_job(h : Hash(String, JSON::Any)) : Job?
      id = h["id"]?.try(&.as_s) || Job.new_id
      name = h["name"]?.try(&.as_s) || id
      schedule = h["schedule"]?.try(&.as_s)
      command = h["command"]?.try(&.as_s)
      return nil unless schedule && command
      kind = h["kind"]?.try(&.as_s) || "shell"
      job = Job.new(id, name, kind, schedule, command)
      job.description = h["description"]?.try(&.as_s) || ""
      job.category = h["category"]?.try(&.as_s) || "default"
      job.timezone = h["timezone"]?.try(&.as_s) || "UTC"
      job.timeout_sec = h["timeout_sec"]?.try(&.as_i) || 0
      job.max_concurrent = h["max_concurrent"]?.try(&.as_i) || 1
      job.enabled = h["enabled"]?.try(&.as_bool?).nil? ? true : h["enabled"].as_bool
      if env_any = h["env"]?
        env_any.as_h.each { |k, v| job.env[k] = v.as_s? || v.to_s }
      end
      job.source = h["source"]?.try(&.as_s) || "api"
      job
    end

    private def bad_request(env, message : String)
      env.response.status_code = 400
      env.response.content_type = "application/json"
      env.response.print({"error" => message}.to_json)
      nil
    end
  end
end
