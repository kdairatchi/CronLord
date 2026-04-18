require "./spec_helper"

describe CronLord::HttpGuard do
  describe ".validate!" do
    it "rejects non-http(s) schemes" do
      expect_raises(CronLord::HttpGuard::Rejected, /unsupported scheme/) do
        CronLord::HttpGuard.validate!("ftp://example.com/x")
      end
    end

    it "rejects a URL with no host" do
      expect_raises(CronLord::HttpGuard::Rejected, /missing host/) do
        CronLord::HttpGuard.validate!("https:///path")
      end
    end

    it "accepts https URL with a real host" do
      uri = CronLord::HttpGuard.validate!("https://example.com/x")
      uri.host.should eq "example.com"
      uri.scheme.should eq "https"
    end

    it "rejects URL outside the prefix allowlist" do
      expect_raises(CronLord::HttpGuard::Rejected, /not in allowlist/) do
        CronLord::HttpGuard.validate!(
          "https://evil.example/webhook",
          allowed_prefixes: ["https://hooks.slack.com/"])
      end
    end

    it "accepts URL that matches a prefix in the allowlist" do
      uri = CronLord::HttpGuard.validate!(
        "https://hooks.slack.com/services/XXX/YYY/ZZZ",
        allowed_prefixes: ["https://hooks.slack.com/"])
      uri.host.should eq "hooks.slack.com"
    end

    it "blocks loopback addresses when allow_private is false" do
      expect_raises(CronLord::HttpGuard::Rejected, /blocked private/) do
        CronLord::HttpGuard.validate!("http://127.0.0.1/x", allow_private: false)
      end
    end

    it "blocks RFC1918 10/8" do
      expect_raises(CronLord::HttpGuard::Rejected, /blocked private/) do
        CronLord::HttpGuard.validate!("http://10.0.0.1/x", allow_private: false)
      end
    end

    it "blocks RFC1918 192.168/16" do
      expect_raises(CronLord::HttpGuard::Rejected, /blocked private/) do
        CronLord::HttpGuard.validate!("http://192.168.1.1/x", allow_private: false)
      end
    end

    it "blocks RFC1918 172.16/12 at both edges" do
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://172.16.0.1/x", allow_private: false)
      end
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://172.31.255.254/x", allow_private: false)
      end
    end

    it "does not treat 172.15.x or 172.32.x as RFC1918" do
      uri = CronLord::HttpGuard.validate!("http://172.15.0.1/x", allow_private: false)
      uri.host.should eq "172.15.0.1"
      uri = CronLord::HttpGuard.validate!("http://172.32.0.1/x", allow_private: false)
      uri.host.should eq "172.32.0.1"
    end

    it "blocks link-local 169.254/16" do
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://169.254.169.254/meta", allow_private: false)
      end
    end

    it "blocks CGNAT 100.64/10" do
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://100.64.0.1/x", allow_private: false)
      end
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://100.127.255.254/x", allow_private: false)
      end
    end

    it "blocks multicast 224/4" do
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://239.0.0.1/x", allow_private: false)
      end
    end

    it "accepts a routable public IPv4 when allow_private is false" do
      uri = CronLord::HttpGuard.validate!("http://8.8.8.8/x", allow_private: false)
      uri.host.should eq "8.8.8.8"
    end

    it "allows loopback when allow_private is true (default)" do
      uri = CronLord::HttpGuard.validate!("http://127.0.0.1/x", allow_private: true)
      uri.host.should eq "127.0.0.1"
    end

    it "blocks IPv6 loopback ::1 when allow_private is false" do
      expect_raises(CronLord::HttpGuard::Rejected) do
        CronLord::HttpGuard.validate!("http://[::1]/x", allow_private: false)
      end
    end
  end

  describe ".safe_client" do
    it "builds an https client with tls and default port 443" do
      uri = URI.parse("https://example.com/x")
      client = CronLord::HttpGuard.safe_client(uri)
      client.host.should eq "example.com"
      client.port.should eq 443
      client.tls?.should_not be_nil
    end

    it "builds an http client with no tls and default port 80" do
      uri = URI.parse("http://example.com/x")
      client = CronLord::HttpGuard.safe_client(uri)
      client.host.should eq "example.com"
      client.port.should eq 80
      client.tls?.should be_nil
    end

    it "honors an explicit port" do
      uri = URI.parse("http://example.com:8080/x")
      client = CronLord::HttpGuard.safe_client(uri)
      client.port.should eq 8080
    end
  end

  describe ".request_path" do
    it "returns / for an empty path" do
      CronLord::HttpGuard.request_path(URI.parse("https://example.com")).should eq "/"
    end

    it "preserves the path" do
      CronLord::HttpGuard.request_path(URI.parse("https://example.com/api/x")).should eq "/api/x"
    end

    it "appends the query string" do
      CronLord::HttpGuard.request_path(URI.parse("https://example.com/x?a=1&b=2"))
        .should eq "/x?a=1&b=2"
    end
  end

  describe ".allow_private_default?" do
    it "is true when CRONLORD_BLOCK_PRIVATE_NETS is unset" do
      ENV.delete("CRONLORD_BLOCK_PRIVATE_NETS")
      CronLord::HttpGuard.allow_private_default?.should be_true
    end

    it "is false when CRONLORD_BLOCK_PRIVATE_NETS=1" do
      ENV["CRONLORD_BLOCK_PRIVATE_NETS"] = "1"
      begin
        CronLord::HttpGuard.allow_private_default?.should be_false
      ensure
        ENV.delete("CRONLORD_BLOCK_PRIVATE_NETS")
      end
    end
  end
end
