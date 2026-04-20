require "./spec_helper"

describe CronLord::GithubSync do
  describe CronLord::GithubSync::Result do
    it "reports ok when errors is empty" do
      r = CronLord::GithubSync::Result.new(imported: 2, updated: 1, errors: [] of String)
      r.ok?.should be_true
      r.total.should eq 3
    end

    it "reports not ok when errors are present" do
      r = CronLord::GithubSync::Result.new(imported: 0, updated: 0, errors: ["fetch error: timeout"])
      r.ok?.should be_false
      r.total.should eq 0
    end

    it "serialises to JSON" do
      r = CronLord::GithubSync::Result.new(imported: 1, updated: 0, errors: [] of String)
      parsed = JSON.parse(r.to_json)
      parsed["imported"].as_i.should eq 1
      parsed["updated"].as_i.should eq 0
      parsed["errors"].as_a.should be_empty
      parsed["synced_at"].as_i64.should be > 0
    end
  end

  describe CronLord::Config::GithubConfig do
    it "is not configured when repo is nil" do
      gc = CronLord::Config::GithubConfig.new
      gc.configured?.should be_false
      gc.raw_url.should be_nil
    end

    it "is configured when repo is set" do
      gc = CronLord::Config::GithubConfig.new(repo: "owner/repo")
      gc.configured?.should be_true
    end

    it "builds the correct raw URL" do
      gc = CronLord::Config::GithubConfig.new(
        repo: "kdairatchi/CronLord",
        branch: "main",
        path: "cronlord.toml",
      )
      gc.raw_url.should eq "https://raw.githubusercontent.com/kdairatchi/CronLord/main/cronlord.toml"
    end

    it "uses custom branch and path in raw URL" do
      gc = CronLord::Config::GithubConfig.new(
        repo: "org/myrepo",
        branch: "production",
        path: "jobs/scheduler.toml",
      )
      gc.raw_url.should eq "https://raw.githubusercontent.com/org/myrepo/production/jobs/scheduler.toml"
    end
  end

  describe ".sync" do
    it "returns an error result when github is not configured" do
      cfg = CronLord::Config.new(
        listen_host: "127.0.0.1",
        listen_port: 7070,
        data_dir: "var",
        db_path: ":memory:",
        log_dir: "var/logs",
        admin_token: nil,
        github_webhook_secret: nil,
        file_jobs: [] of CronLord::Config::FileJob,
        github: CronLord::Config::GithubConfig.new,
      )
      result = CronLord::GithubSync.sync(cfg)
      result.ok?.should be_false
      result.errors.first.should contain "not configured"
    end
  end

  describe "Config.parse_file_jobs_public" do
    it "parses a TOML jobs array" do
      toml_src = <<-TOML
        [[jobs]]
        id       = "spec-job-1"
        name     = "Spec Job"
        schedule = "*/5 * * * *"
        command  = "date -u"
        kind     = "shell"

        [[jobs]]
        id       = "spec-job-2"
        name     = "Spec Job 2"
        schedule = "0 * * * *"
        command  = "echo hi"
        TOML

      doc  = TOML.parse(toml_src)
      jobs = CronLord::Config.parse_file_jobs_public(doc["jobs"]?)
      jobs.size.should eq 2
      jobs.first.id.should eq "spec-job-1"
      jobs.first.kind.should eq "shell"
      jobs.last.schedule.should eq "0 * * * *"
    end

    it "returns an empty array when jobs key is absent" do
      doc  = TOML.parse("# empty")
      jobs = CronLord::Config.parse_file_jobs_public(doc["jobs"]?)
      jobs.should be_empty
    end

    it "skips entries that are missing required fields" do
      toml_src = <<-TOML
        [[jobs]]
        id = "bad-one"
        # missing schedule and command

        [[jobs]]
        id       = "good-one"
        name     = "Good"
        schedule = "* * * * *"
        command  = "true"
        TOML

      doc  = TOML.parse(toml_src)
      jobs = CronLord::Config.parse_file_jobs_public(doc["jobs"]?)
      jobs.size.should eq 1
      jobs.first.id.should eq "good-one"
    end
  end
end
