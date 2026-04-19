require "./spec_helper"

describe CronLord::Doctor do
  it "returns 0 when every check is ok" do
    checks = [
      CronLord::Doctor::Check.new("a", CronLord::Doctor::Status::OK, "ok"),
      CronLord::Doctor::Check.new("b", CronLord::Doctor::Status::OK, "ok"),
    ]
    CronLord::Doctor.exit_code(checks).should eq 0
  end

  it "returns 1 when at least one warn and no failures" do
    checks = [
      CronLord::Doctor::Check.new("a", CronLord::Doctor::Status::OK, "ok"),
      CronLord::Doctor::Check.new("b", CronLord::Doctor::Status::Warn, "meh"),
    ]
    CronLord::Doctor.exit_code(checks).should eq 1
  end

  it "returns 2 when any check fails, regardless of warns" do
    checks = [
      CronLord::Doctor::Check.new("a", CronLord::Doctor::Status::Warn, "meh"),
      CronLord::Doctor::Check.new("b", CronLord::Doctor::Status::Fail, "dead"),
    ]
    CronLord::Doctor.exit_code(checks).should eq 2
  end

  it "Check struct exposes name/status/detail verbatim" do
    c = CronLord::Doctor::Check.new("db", CronLord::Doctor::Status::OK, "integrity ok")
    c.name.should eq "db"
    c.status.should eq CronLord::Doctor::Status::OK
    c.detail.should eq "integrity ok"
  end
end
