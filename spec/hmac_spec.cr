require "./spec_helper"

describe CronLord::Auth::Hmac do
  it "round-trips sign + verify" do
    sig, ts = CronLord::Auth::Hmac.sign("secret", %({"job":"x"}))
    CronLord::Auth::Hmac.verify!("secret", %({"job":"x"}), ts, sig).should be_true
  end

  it "rejects tampered body" do
    sig, ts = CronLord::Auth::Hmac.sign("secret", "original")
    expect_raises(CronLord::Auth::Hmac::VerifyError, /mismatch/) do
      CronLord::Auth::Hmac.verify!("secret", "tampered", ts, sig)
    end
  end

  it "rejects wrong key" do
    sig, ts = CronLord::Auth::Hmac.sign("real", "body")
    CronLord::Auth::Hmac.verify?("wrong", "body", ts, sig).should be_false
  end

  it "rejects stale timestamps outside skew window" do
    now = Time.utc.to_unix
    old = now - 3600
    sig = CronLord::Auth::Hmac.digest_for("k", old, "body")
    expect_raises(CronLord::Auth::Hmac::VerifyError, /skew/) do
      CronLord::Auth::Hmac.verify!("k", "body", old, sig, skew: 60, now: now)
    end
  end

  it "accepts timestamps within skew window" do
    now = 1_700_000_000_i64
    ts = now - 30
    sig = CronLord::Auth::Hmac.digest_for("k", ts, "body")
    CronLord::Auth::Hmac.verify!("k", "body", ts, sig, skew: 60, now: now).should be_true
  end
end
