require "./spec_helper"

describe CronLord::Reaper do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM runs")
    CronLord::DB.conn.exec("DELETE FROM jobs")
  end

  it "marks stuck running rows as fail on boot" do
    job = CronLord::Job.new("reap-job", "Reap", "shell", "*/5 * * * *", "echo")
    job.upsert
    zombie = CronLord::Run.create(job.id, "/tmp/x.log")
    zombie.mark_started
    clean = CronLord::Run.create(job.id, "/tmp/y.log")
    clean.mark_started
    clean.mark_finished("success", 0)

    affected = CronLord::Reaper.reap_zombies!
    affected.should eq 1

    after = CronLord::Run.recent.find { |r| r.id == zombie.id }.not_nil!
    after.status.should eq "fail"
    after.finished_at.should_not be_nil
    after.error.not_nil!.should contain "restarted"
  end

  it "deletes log files older than cutoff" do
    dir = File.tempname("cronlord-reaper", "")
    Dir.mkdir_p(File.join(dir, "job", "day"))
    old_path = File.join(dir, "job", "day", "old.log")
    new_path = File.join(dir, "job", "day", "new.log")
    File.write(old_path, "old")
    File.write(new_path, "new")
    File.touch(old_path, Time.utc - 45.days)

    removed = CronLord::Reaper.purge_logs(dir, 30_i64 * 86_400)
    removed.should eq 1
    File.exists?(old_path).should be_false
    File.exists?(new_path).should be_true
  end
end
