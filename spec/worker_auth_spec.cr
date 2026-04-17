require "./spec_helper"

describe CronLord::Auth::WorkerAuth do
  before_each do
    CronLord::DB.conn.exec("DELETE FROM workers")
  end

  it "accepts a correctly signed request" do
    worker, secret = CronLord::Worker.register("test-worker")
    body = %({"run_id":"abc"})
    ts = Time.utc.to_unix
    sig = CronLord::Auth::Hmac.digest_for(worker.secret_hash, ts, body)

    env = build_env(body: body, headers: {
      CronLord::Auth::WorkerAuth::HEADER_WORKER => worker.id,
      CronLord::Auth::WorkerAuth::HEADER_TS     => ts.to_s,
      CronLord::Auth::WorkerAuth::HEADER_SIG    => sig,
    })

    result = CronLord::Auth::WorkerAuth.authenticate(env, body)
    result.id.should eq worker.id
  end

  it "rejects unknown worker ids" do
    body = "{}"
    env = build_env(body: body, headers: {
      CronLord::Auth::WorkerAuth::HEADER_WORKER => "does-not-exist",
      CronLord::Auth::WorkerAuth::HEADER_TS     => Time.utc.to_unix.to_s,
      CronLord::Auth::WorkerAuth::HEADER_SIG    => "0" * 64,
    })
    expect_raises(CronLord::Auth::WorkerAuth::AuthError, /unknown worker/) do
      CronLord::Auth::WorkerAuth.authenticate(env, body)
    end
  end

  it "rejects a tampered body" do
    worker, _ = CronLord::Worker.register("test-worker")
    ts = Time.utc.to_unix
    sig = CronLord::Auth::Hmac.digest_for(worker.secret_hash, ts, "original")

    env = build_env(body: "tampered", headers: {
      CronLord::Auth::WorkerAuth::HEADER_WORKER => worker.id,
      CronLord::Auth::WorkerAuth::HEADER_TS     => ts.to_s,
      CronLord::Auth::WorkerAuth::HEADER_SIG    => sig,
    })
    expect_raises(CronLord::Auth::WorkerAuth::AuthError) do
      CronLord::Auth::WorkerAuth.authenticate(env, "tampered")
    end
  end

  it "rejects disabled workers" do
    worker, _ = CronLord::Worker.register("test-worker")
    worker.enabled = false
    worker.upsert
    ts = Time.utc.to_unix
    sig = CronLord::Auth::Hmac.digest_for(worker.secret_hash, ts, "")
    env = build_env(body: "", headers: {
      CronLord::Auth::WorkerAuth::HEADER_WORKER => worker.id,
      CronLord::Auth::WorkerAuth::HEADER_TS     => ts.to_s,
      CronLord::Auth::WorkerAuth::HEADER_SIG    => sig,
    })
    expect_raises(CronLord::Auth::WorkerAuth::AuthError, /disabled/) do
      CronLord::Auth::WorkerAuth.authenticate(env, "")
    end
  end
end
