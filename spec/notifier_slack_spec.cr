require "./spec_helper"

private def make_job(args : Hash(String, JSON::Any) = {} of String => JSON::Any) : CronLord::Job
  job = CronLord::Job.new("job-1", "Nightly backup", "shell", "@daily", "backup.sh")
  job.args = args
  job
end

private def make_run(status : String, exit_code : Int32? = 0, error : String? = nil) : CronLord::Run
  run = CronLord::Run.new("run-abc123", "job-1", status, "/tmp/run.log")
  run.exit_code = exit_code
  run.error = error
  run.trigger = "schedule"
  run.started_at = 1_700_000_000_i64
  run.finished_at = 1_700_000_042_i64
  run
end

describe CronLord::Notifier do
  describe ".status_tag" do
    it "uses [ok] for success, no emoji" do
      CronLord::Notifier.status_tag("success").should eq "[ok]"
      CronLord::Notifier.status_tag("fail").should eq "[fail]"
      CronLord::Notifier.status_tag("timeout").should eq "[timeout]"
      CronLord::Notifier.status_tag("cancelled").should eq "[cancelled]"
      CronLord::Notifier.status_tag("weird").should eq "[weird]"
    end
  end

  describe ".slack_payload" do
    it "builds Block Kit JSON with summary, fields, and no emoji" do
      job = make_job
      run = make_run("success", 0)
      payload = CronLord::Notifier.slack_payload(job, run)
      json = payload.to_json
      json.should contain "[ok] Nightly backup"
      json.should contain "*Status:*"
      json.should contain "*Duration:*\\n42s"
      json.should contain "*Exit:*"
      json.should_not match(/:[a-z_]+:/) # no shortcodes like :check:
    end

    it "includes an error block when run failed" do
      job = make_job
      run = make_run("fail", 1, "command not found")
      json = CronLord::Notifier.slack_payload(job, run).to_json
      json.should contain "[fail] Nightly backup"
      json.should contain "command not found"
    end

    it "omits the error block on clean runs" do
      job = make_job
      run = make_run("success", 0, nil)
      json = CronLord::Notifier.slack_payload(job, run).to_json
      json.should_not contain "*Error:*"
    end
  end

  describe ".webhook_payload" do
    it "still carries the run fields for generic webhooks" do
      job = make_job
      run = make_run("success", 0)
      payload = CronLord::Notifier.webhook_payload(job, run)
      payload["job_id"].should eq "job-1"
      payload["status"].should eq "success"
      payload["run_id"].should eq "run-abc123"
    end
  end

  describe ".deliver_slack" do
    it "ignores a non-Slack URL and does not raise" do
      args = {"slack_webhook_url" => JSON::Any.new("https://evil.example.com/hook")}
      job = make_job(args)
      run = make_run("success", 0)
      # Must not spawn a delivery fiber or raise.
      CronLord::Notifier.deliver_slack(job, run)
    end

    it "is a no-op when no slack_webhook_url is set" do
      job = make_job
      run = make_run("success", 0)
      CronLord::Notifier.deliver_slack(job, run)
    end
  end
end
