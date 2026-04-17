require "./spec_helper"

describe CronLord::ViewHelpers do
  describe ".relative_time" do
    it "returns 'never' for nil" do
      CronLord::ViewHelpers.relative_time(nil).should eq "never"
    end

    it "formats seconds" do
      CronLord::ViewHelpers.relative_time(Time.utc.to_unix - 30).should eq "30s ago"
    end

    it "formats minutes" do
      CronLord::ViewHelpers.relative_time(Time.utc.to_unix - 600).should eq "10m ago"
    end

    it "formats hours" do
      CronLord::ViewHelpers.relative_time(Time.utc.to_unix - 7200).should eq "2h ago"
    end

    it "formats days" do
      CronLord::ViewHelpers.relative_time(Time.utc.to_unix - 172_800).should eq "2d ago"
    end

    it "returns 'just now' for recent" do
      CronLord::ViewHelpers.relative_time(Time.utc.to_unix - 2).should eq "just now"
    end
  end

  describe ".worker_state" do
    it "reports disabled when enabled is false" do
      worker = CronLord::Worker.new("id", "n", "hash")
      worker.enabled = false
      CronLord::ViewHelpers.worker_state(worker).should eq "disabled"
    end

    it "reports idle when never seen" do
      worker = CronLord::Worker.new("id", "n", "hash")
      CronLord::ViewHelpers.worker_state(worker).should eq "idle"
    end

    it "reports online within 2 minutes" do
      worker = CronLord::Worker.new("id", "n", "hash")
      worker.last_seen = Time.utc.to_unix - 30
      CronLord::ViewHelpers.worker_state(worker).should eq "online"
    end

    it "reports stale between 2 minutes and 1 hour" do
      worker = CronLord::Worker.new("id", "n", "hash")
      worker.last_seen = Time.utc.to_unix - 600
      CronLord::ViewHelpers.worker_state(worker).should eq "stale"
    end

    it "reports idle beyond 1 hour" do
      worker = CronLord::Worker.new("id", "n", "hash")
      worker.last_seen = Time.utc.to_unix - 7200
      CronLord::ViewHelpers.worker_state(worker).should eq "idle"
    end
  end
end
