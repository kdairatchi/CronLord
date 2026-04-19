require "json"
require "process"
require "http/client"
require "uri"

module CronLord
  # Local executor used by the reference worker. Runs the payload shipped
  # by the scheduler without touching the scheduler's DB - output is
  # captured into a bounded String and returned so the caller can POST it
  # to /api/workers/finish.
  class WorkerRunner
    MAX_LOG_BYTES = 512 * 1024 # 512 KiB; server rejects larger bodies quickly

    record Result,
      status : String, # "success" | "fail" | "timeout" | "cancelled"
      exit_code : Int32?,
      error : String?,
      log : String

    def self.run(job : JSON::Any, *, cancel_chan : Channel(Nil)? = nil) : Result
      kind = job["kind"]?.try(&.as_s?) || "shell"
      case kind
      when "shell" then run_shell(job, cancel_chan)
      when "http"  then run_http(job)
      else              unsupported(kind)
      end
    end

    private def self.unsupported(kind : String) : Result
      Result.new(
        status: "fail",
        exit_code: nil,
        error: "worker does not support kind: #{kind}",
        log: "[worker] unsupported kind '#{kind}' - requeue with executor=local",
      )
    end

    private def self.run_shell(job : JSON::Any, cancel_chan : Channel(Nil)?) : Result
      command = job["command"]?.try(&.as_s?) || ""
      timeout = job["timeout_sec"]?.try(&.as_i?) || 0
      chdir = job["working_dir"]?.try(&.as_s?)

      env_overrides = {} of String => String
      if env_h = job["env"]?.try(&.as_h?)
        env_h.each { |k, v| env_overrides[k] = v.as_s? || v.to_s }
      end
      env = ENV.to_h.merge(env_overrides)

      if chdir && !Dir.exists?(chdir)
        return Result.new("fail", 127, "working_dir missing: #{chdir}",
          "[worker] working_dir does not exist: #{chdir}")
      end

      log = String::Builder.new
      log << "$ " << command << '\n'

      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe

      process = Process.new(
        command: command,
        shell: true,
        env: env,
        clear_env: false,
        chdir: chdir,
        input: Process::Redirect::Close,
        output: stdout_w,
        error: stderr_w,
      )
      stdout_w.close
      stderr_w.close

      done_out = Channel(Nil).new
      done_err = Channel(Nil).new
      mutex = Mutex.new
      bytes = Atomic(Int64).new(0_i64)
      spawn pipe_into(stdout_r, log, "out", done_out, mutex, bytes)
      spawn pipe_into(stderr_r, log, "err", done_err, mutex, bytes)

      waiter = Channel(Process::Status).new(1)
      spawn { waiter.send(process.wait) }

      status : Process::Status? = nil
      timed_out = false
      cancelled = false
      effective_cancel = cancel_chan || Channel(Nil).new # never-fires fallback

      if timeout > 0
        select
        when st = waiter.receive
          status = st
        when effective_cancel.receive
          cancelled = true
          kill_process(process)
          status = waiter.receive
        when timeout(timeout.seconds)
          timed_out = true
          kill_process(process)
          status = waiter.receive
        end
      else
        select
        when st = waiter.receive
          status = st
        when effective_cancel.receive
          cancelled = true
          kill_process(process)
          status = waiter.receive
        end
      end

      done_out.receive
      done_err.receive

      st = status.not_nil!
      captured = log.to_s
      # Signal-exit (our SIGKILL on timeout/cancel) has no numeric exit code.
      code = st.normal_exit? ? st.exit_code : nil
      if cancelled
        Result.new("cancelled", code, "cancelled by operator",
          captured + "\n[worker] cancelled by operator; killed\n")
      elsif timed_out
        Result.new("timeout", code, "timeout after #{timeout}s", captured)
      elsif st.success?
        Result.new("success", code, nil, captured)
      else
        Result.new("fail", code, nil, captured)
      end
    end

    private def self.kill_process(process)
      process.signal(Signal::TERM) rescue nil
      sleep 2.seconds
      process.signal(Signal::KILL) rescue nil
    end

    private def self.pipe_into(io : IO, log : String::Builder, stream : String,
                               done : Channel(Nil), mutex : Mutex, bytes : Atomic(Int64))
      while line = io.gets(chomp: true)
        formatted = "#{Time.utc.to_rfc3339} #{stream} #{line}\n"
        mutex.synchronize do
          if bytes.get + formatted.bytesize <= MAX_LOG_BYTES
            log << formatted
            bytes.add(formatted.bytesize.to_i64)
          elsif bytes.get < MAX_LOG_BYTES
            log << "[worker] log truncated at #{MAX_LOG_BYTES} bytes\n"
            bytes.set((MAX_LOG_BYTES + 1).to_i64)
          end
        end
      end
    rescue ex : IO::Error
      mutex.synchronize { log << "[worker] pipe error: #{ex.message}\n" }
    ensure
      io.close rescue nil
      done.send(nil)
    end

    private def self.run_http(job : JSON::Any) : Result
      command = job["command"]?.try(&.as_s?) || ""
      timeout = job["timeout_sec"]?.try(&.as_i?) || 30
      method, url_str, headers_h, body, expect_status = parse_http_command(command)

      uri = URI.parse(url_str)
      unless {"http", "https"}.includes?(uri.scheme)
        return Result.new("fail", nil, "disallowed scheme: #{uri.scheme}",
          "[worker] only http/https allowed; got #{uri.scheme}")
      end

      log = String::Builder.new
      log << "> " << method << ' ' << url_str << '\n'
      headers = HTTP::Headers.new
      headers_h.each { |k, v| headers[k] = v }

      response =
        case method.upcase
        when "GET"    then HTTP::Client.get(url_str, headers: headers)
        when "POST"   then HTTP::Client.post(url_str, headers: headers, body: body)
        when "PUT"    then HTTP::Client.put(url_str, headers: headers, body: body)
        when "DELETE" then HTTP::Client.delete(url_str, headers: headers)
        else
          return Result.new("fail", nil, "unsupported method: #{method}",
            "[worker] unsupported HTTP method: #{method}")
        end

      log << "< " << response.status_code.to_s << '\n'
      snippet = response.body.to_s
      snippet = snippet[0, 32 * 1024] if snippet.bytesize > 32 * 1024
      log << snippet << '\n'

      ok = expect_status ? (response.status_code == expect_status) : response.success?
      status = ok ? "success" : "fail"
      err = ok ? nil : "unexpected status #{response.status_code}"
      Result.new(status, response.status_code, err, log.to_s)
    rescue ex
      Result.new("fail", nil, ex.message, "[worker] http error: #{ex.message}")
    end

    private def self.parse_http_command(command : String)
      s = command.strip
      return {"GET", s, {} of String => String, nil, nil} unless s.starts_with?('{')
      h = JSON.parse(s).as_h
      method = h["method"]?.try(&.as_s?) || "GET"
      url = h["url"]?.try(&.as_s?) || ""
      headers = {} of String => String
      if hh = h["headers"]?.try(&.as_h?)
        hh.each { |k, v| headers[k] = v.as_s? || v.to_s }
      end
      body = h["body"]?.try(&.as_s?)
      expect = h["expect_status"]?.try(&.as_i?)
      {method, url, headers, body, expect}
    end
  end
end
