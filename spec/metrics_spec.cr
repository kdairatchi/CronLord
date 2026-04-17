require "./spec_helper"

describe CronLord::Metrics do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM runs")
    CronLord::DB.conn.exec("DELETE FROM jobs")
  end

  it "renders Prometheus text with core metrics" do
    job = CronLord::Job.new("metric-job", "Metric", "shell", "*/5 * * * *", "echo")
    job.upsert
    run = CronLord::Run.create(job.id, "/tmp/nope.log")
    run.mark_started
    run.mark_finished("success", 0)

    cfg = CronLord::Config.load("cronlord.toml")
    sched = CronLord::Scheduler.new(cfg)
    output = CronLord::Metrics.render(sched)

    output.should contain "cronlord_jobs_total 1"
    output.should contain "cronlord_jobs_enabled 1"
    output.should contain %(cronlord_runs_total{status="success"} 1)
    output.should contain "cronlord_build_info"
  end

  it "handles empty state" do
    cfg = CronLord::Config.load("cronlord.toml")
    sched = CronLord::Scheduler.new(cfg)
    output = CronLord::Metrics.render(sched)
    output.should contain "cronlord_jobs_total 0"
    output.should contain "cronlord_last_finish_age_seconds 0"
  end
end
