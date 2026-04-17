require "./spec_helper"

private NY = Time::Location.load("America/New_York")

describe "Cron timezone" do
  it "fires @daily at local midnight in the configured timezone" do
    cron = CronLord::Cron.parse("@daily")
    # 2026-04-17 in NY: EDT = UTC-4, so local midnight = 04:00 UTC.
    from = Time.utc(2026, 4, 17, 5, 0)
    fire = cron.next_after(from, NY)
    fire.should_not be_nil
    fire.not_nil!.to_s("%F %H:%M UTC").should eq "2026-04-18 04:00 UTC"
    fire.not_nil!.in(NY).to_s("%F %H:%M").should eq "2026-04-18 00:00"
  end

  it "fires at local 09:00 across a DST spring-forward boundary" do
    cron = CronLord::Cron.parse("0 9 * * *")
    from = Time.utc(2026, 3, 7, 20, 0) # Sat 15:00 EST
    fire = cron.next_after(from, NY)
    fire.not_nil!.in(NY).to_s("%F %H:%M").should eq "2026-03-08 09:00"
    after_dst = cron.next_after(fire.not_nil!, NY)
    after_dst.not_nil!.in(NY).to_s("%F %H:%M").should eq "2026-03-09 09:00"
  end

  it "skips the missing hour on DST spring-forward" do
    # 02:30 local doesn't exist on 2026-03-08 in NY.
    cron = CronLord::Cron.parse("30 2 * * *")
    from = Time.utc(2026, 3, 8, 5, 0) # just before the transition in UTC
    fire = cron.next_after(from, NY)
    # Next fire is the following day at 02:30 EDT.
    fire.not_nil!.in(NY).to_s("%F %H:%M").should eq "2026-03-09 02:30"
  end

  it "fires the repeated local hour only once on DST fall-back" do
    # 01:30 local occurs twice on 2026-11-01 in NY.
    cron = CronLord::Cron.parse("30 1 * * *")
    from = Time.utc(2026, 10, 31, 12, 0)
    first = cron.next_after(from, NY)
    first.not_nil!.in(NY).to_s("%F %H:%M").should eq "2026-11-01 01:30"
    first.not_nil!.to_s("%F %H:%M UTC").should eq "2026-11-01 05:30 UTC"
    # The next call must not return the second (EST) 01:30.
    second = cron.next_after(first.not_nil!, NY)
    second.not_nil!.in(NY).to_s("%F %H:%M").should eq "2026-11-02 01:30"
  end

  it "next_n walks through fires in the configured timezone" do
    cron = CronLord::Cron.parse("0 9 * * *")
    from = Time.utc(2026, 4, 17, 20, 0)
    fires = cron.next_n(3, from, NY)
    fires.size.should eq 3
    fires.map { |t| t.in(NY).to_s("%F %H:%M") }.should eq [
      "2026-04-18 09:00",
      "2026-04-19 09:00",
      "2026-04-20 09:00",
    ]
  end

  it "defaults to UTC when no location is passed" do
    cron = CronLord::Cron.parse("0 9 * * *")
    from = Time.utc(2026, 4, 17, 6, 0)
    fire = cron.next_after(from)
    fire.not_nil!.to_s("%F %H:%M UTC").should eq "2026-04-17 09:00 UTC"
  end
end

describe CronLord::Job do
  it "resolves a known timezone" do
    job = CronLord::Job.new("id1", "n", "shell", "@daily", "true")
    job.timezone = "America/New_York"
    job.location.name.should eq "America/New_York"
  end

  it "raises ArgumentError for an unknown timezone" do
    job = CronLord::Job.new("id2", "n", "shell", "@daily", "true")
    job.timezone = "Moon/Tranquility"
    expect_raises(ArgumentError, /unknown timezone/) { job.location }
  end
end
