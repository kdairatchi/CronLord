require "./spec_helper"
require "http/client"
require "http/server"

# Helper: boot a Kemal-less but route-compatible HTTP server? Too heavy.
# Instead exercise Run.try_lease! + Reaper.expire_stale_leases! directly;
# route wiring is covered by the auth + hmac spec below.

describe CronLord::Run do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM runs")
    CronLord::DB.conn.exec("DELETE FROM jobs")
  end

  describe ".try_lease!" do
    it "hands out the oldest queued run and flips it to running" do
      job = CronLord::Job.new("j1", "Job", "shell", "*/5 * * * *", "echo")
      job.executor = "worker"
      job.upsert
      run = CronLord::Run.create(job.id, "/tmp/a.log")
      leased = CronLord::Run.try_lease!("worker-1", 60, [job.id])
      leased.should_not be_nil
      leased.not_nil!.id.should eq run.id
      leased.not_nil!.status.should eq "running"
      leased.not_nil!.worker_id.should eq "worker-1"
      leased.not_nil!.lease_expires_at.should_not be_nil
    end

    it "returns nil when nothing is queued" do
      CronLord::Run.try_lease!("worker-1", 60, ["nope"]).should be_nil
    end

    it "refuses to lease something another worker already holds" do
      job = CronLord::Job.new("j2", "Job", "shell", "*/5 * * * *", "echo")
      job.executor = "worker"
      job.upsert
      CronLord::Run.create(job.id, "/tmp/a.log")
      first = CronLord::Run.try_lease!("worker-A", 60, [job.id])
      first.should_not be_nil
      second = CronLord::Run.try_lease!("worker-B", 60, [job.id])
      second.should be_nil
    end
  end

  describe "#heartbeat! / #finish_from_worker!" do
    it "heartbeat bumps the lease window" do
      job = CronLord::Job.new("j3", "Job", "shell", "*/5 * * * *", "echo")
      job.executor = "worker"
      job.upsert
      CronLord::Run.create(job.id, "/tmp/a.log")
      run = CronLord::Run.try_lease!("w", 10, [job.id]).not_nil!
      before = run.lease_expires_at.not_nil!
      sleep 1.second
      run.heartbeat!(30)
      run.lease_expires_at.not_nil!.should be > before
    end

    it "finish_from_worker marks terminal and clears lease" do
      job = CronLord::Job.new("j4", "Job", "shell", "*/5 * * * *", "echo")
      job.executor = "worker"
      job.upsert
      CronLord::Run.create(job.id, "/tmp/a.log")
      run = CronLord::Run.try_lease!("w", 60, [job.id]).not_nil!
      run.finish_from_worker!("success", 0, nil)
      reloaded = CronLord::Run.find(run.id).not_nil!
      reloaded.status.should eq "success"
      reloaded.exit_code.should eq 0
      reloaded.lease_expires_at.should be_nil
      reloaded.finished_at.should_not be_nil
    end
  end
end

describe CronLord::Reaper do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM runs")
    CronLord::DB.conn.exec("DELETE FROM jobs")
  end

  it "re-queues runs whose lease has expired" do
    job = CronLord::Job.new("jr", "Job", "shell", "*/5 * * * *", "echo")
    job.executor = "worker"
    job.upsert
    CronLord::Run.create(job.id, "/tmp/a.log")
    run = CronLord::Run.try_lease!("w", 60, [job.id]).not_nil!
    # Simulate stale lease by rewriting lease_expires_at to the past.
    CronLord::DB.conn.exec("UPDATE runs SET lease_expires_at=? WHERE id=?",
      Time.utc.to_unix - 3600, run.id)
    CronLord::Reaper.expire_stale_leases!.should be >= 1
    after = CronLord::Run.find(run.id).not_nil!
    after.status.should eq "queued"
    after.worker_id.should be_nil
    after.lease_expires_at.should be_nil
  end
end
