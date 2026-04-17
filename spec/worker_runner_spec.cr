require "./spec_helper"

describe CronLord::WorkerRunner do
  describe ".run shell" do
    it "captures stdout of a successful command" do
      job = JSON.parse(%({"kind":"shell","command":"echo hello-worker"}))
      result = CronLord::WorkerRunner.run(job)
      result.status.should eq "success"
      result.exit_code.should eq 0
      result.log.should contain "hello-worker"
    end

    it "marks fail on non-zero exit" do
      job = JSON.parse(%({"kind":"shell","command":"false"}))
      result = CronLord::WorkerRunner.run(job)
      result.status.should eq "fail"
      result.exit_code.should_not eq 0
    end

    it "reports timeout when command exceeds timeout_sec" do
      job = JSON.parse(%({"kind":"shell","command":"sleep 5","timeout_sec":1}))
      result = CronLord::WorkerRunner.run(job)
      result.status.should eq "timeout"
      result.error.not_nil!.should contain "timeout"
    end

    it "rejects missing working_dir cleanly" do
      job = JSON.parse(%({"kind":"shell","command":"pwd","working_dir":"/nope/nonexistent/cronlord"}))
      result = CronLord::WorkerRunner.run(job)
      result.status.should eq "fail"
      result.exit_code.should eq 127
      result.error.not_nil!.should contain "working_dir"
    end
  end

  describe ".run unknown kind" do
    it "returns a fail result for unsupported kinds" do
      job = JSON.parse(%({"kind":"claude","command":"hello"}))
      result = CronLord::WorkerRunner.run(job)
      result.status.should eq "fail"
      result.error.not_nil!.should contain "kind"
    end
  end
end
