require "./spec_helper"

private def next_at(expr : String, from : String) : String
  t = Time.parse_utc(from, "%F %T")
  CronLord::Cron.parse(expr).next_after(t).try(&.to_s("%F %T")) || "nil"
end

describe CronLord::Cron do
  it "rejects wrong field counts" do
    expect_raises(CronLord::Cron::ParseError) { CronLord::Cron.parse("* * *") }
  end

  it "expands macros" do
    c = CronLord::Cron.parse("@daily")
    c.minute.should eq [0]
    c.hour.should eq [0]
  end

  it "expands steps" do
    c = CronLord::Cron.parse("*/15 * * * *")
    c.minute.should eq [0, 15, 30, 45]
  end

  it "expands lists and ranges" do
    c = CronLord::Cron.parse("0,30 9-17 * * 1-5")
    c.minute.should eq [0, 30]
    c.hour.should eq (9..17).to_a
    c.dow.should eq [1, 2, 3, 4, 5]
  end

  it "handles month names" do
    c = CronLord::Cron.parse("0 0 1 JAN *")
    c.month.should eq [1]
  end

  it "handles day names" do
    c = CronLord::Cron.parse("0 9 * * MON")
    c.dow.should eq [1]
  end

  it "normalizes dow 7 as sunday" do
    CronLord::Cron.parse("0 9 * * 7").dow.should eq [0]
  end

  it "computes next fire for */5" do
    next_at("*/5 * * * *", "2026-04-17 12:03:22").should eq "2026-04-17 12:05:00"
  end

  it "computes next fire for @daily rolling to next day" do
    next_at("@daily", "2026-04-17 23:59:00").should eq "2026-04-18 00:00:00"
  end

  it "handles dom+dow OR semantics" do
    next_at("0 12 15 * MON", "2026-04-14 00:00:00").should eq "2026-04-15 12:00:00"
    next_at("0 12 15 * MON", "2026-04-16 00:00:00").should eq "2026-04-20 12:00:00"
  end

  it "handles dom-only schedules" do
    next_at("0 0 31 * *", "2026-04-01 00:00:00").should eq "2026-05-31 00:00:00"
  end
end
