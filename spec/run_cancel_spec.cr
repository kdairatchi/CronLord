require "./spec_helper"

describe "run cancellation" do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM runs")
    CronLord::DB.conn.exec("DELETE FROM jobs")
  end

  describe CronLord::Runner::CancelRegistry do
    it "signals registered runs and is no-op for unknown ids" do
      chan = CronLord::Runner::CancelRegistry.register("abc")
      CronLord::Runner::CancelRegistry.signal("abc").should be_true
      chan.receive.should be_nil
      CronLord::Runner::CancelRegistry.signal("ghost").should be_false
    ensure
      CronLord::Runner::CancelRegistry.unregister("abc")
    end

    it "unregister removes the entry" do
      CronLord::Runner::CancelRegistry.register("dead")
      CronLord::Runner::CancelRegistry.unregister("dead")
      CronLord::Runner::CancelRegistry.signal("dead").should be_false
    end
  end

  describe CronLord::Run do
    it "cancel_queued! flips a queued run and no-ops on running/terminal" do
      job = CronLord::Job.new("j1", "J1", "shell", "*/5 * * * *", "echo")
      job.upsert

      queued = CronLord::Run.create(job.id, "/tmp/l.log")
      CronLord::Run.cancel_queued!(queued.id).should be_true
      CronLord::Run.find(queued.id).not_nil!.status.should eq "cancelled"

      running = CronLord::Run.create(job.id, "/tmp/m.log")
      running.mark_started
      CronLord::Run.cancel_queued!(running.id).should be_false
      CronLord::Run.find(running.id).not_nil!.status.should eq "running"

      # Running doesn't become cancelled, only cancelling.
      CronLord::Run.mark_cancelling!(running.id).should be_true
      CronLord::Run.find(running.id).not_nil!.status.should eq "cancelling"

      # Second call after the state changed is a no-op (already cancelling).
      CronLord::Run.mark_cancelling!(running.id).should be_false
    end

    it "mark_cancelling! refuses to move a terminal run" do
      job = CronLord::Job.new("j2", "J2", "shell", "*/5 * * * *", "echo")
      job.upsert
      done = CronLord::Run.create(job.id, "/tmp/n.log")
      done.mark_started
      done.mark_finished("success", 0)
      CronLord::Run.mark_cancelling!(done.id).should be_false
      CronLord::Run.find(done.id).not_nil!.status.should eq "success"
    end
  end
end
