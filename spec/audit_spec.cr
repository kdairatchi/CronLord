require "./spec_helper"

describe CronLord::Audit do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM audit")
  end

  it "writes and reads entries" do
    CronLord::Audit.write("job.create", actor: "kdairatchi", target: "job:abc",
      meta: {"name" => JSON::Any.new("deploy")})
    entries = CronLord::Audit.recent
    entries.size.should eq 1
    entries.first.action.should eq "job.create"
    entries.first.target.should eq "job:abc"
    entries.first.meta["name"].as_s.should eq "deploy"
  end

  it "orders most recent first" do
    CronLord::Audit.write("a.first")
    sleep 1.second
    CronLord::Audit.write("b.second")
    entries = CronLord::Audit.recent(limit: 5)
    entries.first.action.should eq "b.second"
    entries[1].action.should eq "a.first"
  end

  it "survives missing meta_json gracefully" do
    CronLord::DB.conn.exec(
      "INSERT INTO audit (at, actor, action, target, meta_json) VALUES (?,?,?,?,?)",
      Time.utc.to_unix, "system", "legacy", "x", "")
    entries = CronLord::Audit.recent
    entries.any? { |e| e.action == "legacy" }.should be_true
  end
end
