require "./spec_helper"
require "http/server"

ensure_test_db

private def with_server(handler : HTTP::Server::Context ->) : {String, HTTP::Server}
  server = HTTP::Server.new(handler)
  addr = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  { "http://#{addr}", server }
end

private def fresh_job(id : String, command : String, *,
                     kind : String = "http", timeout_sec : Int32 = 10) : CronLord::Job
  j = CronLord::Job.new(id: id, name: id, kind: kind, schedule: "@hourly", command: command)
  j.timeout_sec = timeout_sec
  j
end

private def fresh_run(job_id : String) : {CronLord::Run, CronLord::LogBuffer, String}
  path = File.tempname("cronlord-test", ".log")
  run = CronLord::Run.new(id: CronLord::Run.new_id, job_id: job_id, status: "queued", log_path: path)
  { run, CronLord::LogBuffer.new(path), path }
end

describe CronLord::Runner::Http do
  it "marks success on 200" do
    url, server = with_server ->(ctx : HTTP::Server::Context) {
      ctx.response.status_code = 200
      ctx.response.print("hello")
    }
    begin
      job = fresh_job("http-ok", url)
      run, buf, path = fresh_run(job.id)
      code = CronLord::Runner::Http.run(job, run, buf)
      code.should eq 200
      run.status.should eq "success"
      run.exit_code.should eq 200
      File.read(path).should contain("HTTP 200")
    ensure
      server.close
    end
  end

  it "marks fail on non-2xx without expect" do
    url, server = with_server ->(ctx : HTTP::Server::Context) {
      ctx.response.status_code = 503
      ctx.response.print("nope")
    }
    begin
      job = fresh_job("http-fail", url)
      run, buf, _ = fresh_run(job.id)
      CronLord::Runner::Http.run(job, run, buf)
      run.status.should eq "fail"
      run.exit_code.should eq 503
    ensure
      server.close
    end
  end

  it "respects expect_status" do
    url, server = with_server ->(ctx : HTTP::Server::Context) {
      ctx.response.status_code = 201
    }
    begin
      cmd = {"method" => "POST", "url" => url, "expect_status" => 201}.to_json
      job = fresh_job("http-expect", cmd)
      run, buf, _ = fresh_run(job.id)
      CronLord::Runner::Http.run(job, run, buf)
      run.status.should eq "success"
    ensure
      server.close
    end
  end

  it "rejects non-http schemes" do
    job = fresh_job("http-bad", "file:///etc/passwd")
    run, buf, _ = fresh_run(job.id)
    CronLord::Runner::Http.run(job, run, buf).should eq 2
    run.status.should eq "fail"
  end

  it "parses JSON body and headers" do
    seen_method = ""
    seen_header = ""
    url, server = with_server ->(ctx : HTTP::Server::Context) {
      seen_method = ctx.request.method
      seen_header = ctx.request.headers["X-Token"]? || ""
      ctx.response.status_code = 204
    }
    begin
      cmd = {
        "method"  => "PUT",
        "url"     => url,
        "headers" => {"X-Token" => "abc"},
        "body"    => %({"ping":true}),
      }.to_json
      job = fresh_job("http-post", cmd)
      run, buf, _ = fresh_run(job.id)
      CronLord::Runner::Http.run(job, run, buf)
      seen_method.should eq "PUT"
      seen_header.should eq "abc"
    ensure
      server.close
    end
  end
end

describe CronLord::Notifier do
  it "posts JSON payload on run finish" do
    received = Channel(String).new(1)
    url, server = with_server ->(ctx : HTTP::Server::Context) {
      body = ctx.request.body.try &.gets_to_end
      received.send(body || "")
      ctx.response.status_code = 200
    }
    begin
      job = CronLord::Job.new(id: "nf-1", name: "nf", kind: "shell",
        schedule: "@hourly", command: "true")
      job.args = {"webhook_url" => JSON::Any.new(url)}
      run = CronLord::Run.new(id: "r-nf-1", job_id: job.id, status: "success", log_path: "/tmp/x")
      run.exit_code = 0
      run.started_at = Time.utc.to_unix
      run.finished_at = Time.utc.to_unix
      run.trigger = "schedule"

      CronLord::Notifier.deliver(job, run)
      body = received.receive
      parsed = JSON.parse(body)
      parsed["job_id"].as_s.should eq "nf-1"
      parsed["run_id"].as_s.should eq "r-nf-1"
      parsed["status"].as_s.should eq "success"
      parsed["exit_code"].as_i.should eq 0
    ensure
      server.close
    end
  end

  it "noop when no webhook_url configured" do
    job = CronLord::Job.new(id: "nf-noop", name: "no", kind: "shell",
      schedule: "@hourly", command: "true")
    run = CronLord::Run.new(id: "r-noop", job_id: job.id, status: "success", log_path: "/tmp/x")
    # Should not raise, should not block.
    CronLord::Notifier.deliver(job, run)
  end
end
