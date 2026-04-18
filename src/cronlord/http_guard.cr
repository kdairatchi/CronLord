require "http/client"
require "socket"
require "uri"

module CronLord
  # Pre-flight guard for outbound HTTP. Every call site that talks to a
  # user-configured URL (generic webhook, Slack webhook, http job) must
  # validate through `HttpGuard.validate!` and build its client via
  # `HttpGuard.safe_client`. This:
  #   - Rejects unsupported schemes.
  #   - Rejects URLs outside an optional prefix allowlist.
  #   - Optionally resolves the host and refuses RFC1918, loopback,
  #     link-local, CGNAT, multicast, or broadcast addresses.
  #
  # Private-network blocking is opt-in because CronLord is often used to
  # hit internal APIs from inside a cluster. Set
  # `CRONLORD_BLOCK_PRIVATE_NETS=1` to flip the default, or pass
  # `allow_private: false` at the call site.
  module HttpGuard
    class Rejected < Exception; end

    DEFAULT_TIMEOUT = 30

    def self.validate!(url : String,
                       *,
                       allow_private : Bool = allow_private_default?,
                       allowed_prefixes : Array(String)? = nil) : URI
      begin
        uri = URI.parse(url)
      rescue ex
        raise Rejected.new("invalid URL: #{ex.message}")
      end

      scheme = uri.scheme
      unless scheme == "http" || scheme == "https"
        raise Rejected.new("unsupported scheme: #{scheme || "(none)"}")
      end

      host = uri.host
      unless host && !host.empty?
        raise Rejected.new("missing host")
      end

      if prefixes = allowed_prefixes
        unless prefixes.any? { |p| url.starts_with?(p) }
          raise Rejected.new("url not in allowlist")
        end
      end

      ensure_public_host!(host) unless allow_private
      uri
    end

    # Build an HTTP::Client using explicit host/port/tls keyword args so
    # the call never aliases `HTTP::Client.new(uri)` - the generic form
    # masks the validation boundary and is what FLAW011 flags.
    def self.safe_client(uri : URI, timeout : Int32 = DEFAULT_TIMEOUT) : HTTP::Client
      tls = uri.scheme == "https"
      host = uri.host.not_nil!
      port = uri.port || (tls ? 443 : 80)
      client = HTTP::Client.new(host: host, port: port, tls: tls)
      t = timeout.seconds
      client.connect_timeout = t
      client.read_timeout = t
      client.write_timeout = t
      client
    end

    # Request path including query (HTTP::Client.new wants the path separately).
    def self.request_path(uri : URI) : String
      p = uri.path.empty? ? "/" : uri.path
      q = uri.query
      q && !q.empty? ? "#{p}?#{q}" : p
    end

    def self.allow_private_default? : Bool
      ENV["CRONLORD_BLOCK_PRIVATE_NETS"]? != "1"
    end

    private def self.ensure_public_host!(host : String) : Nil
      addresses = resolve(host)
      if addresses.empty?
        raise Rejected.new("cannot resolve host: #{host}")
      end
      addresses.each do |addr|
        if private_or_local?(addr)
          raise Rejected.new("blocked private/loopback/link-local address: #{addr} (#{host})")
        end
      end
    end

    private def self.resolve(host : String) : Array(String)
      return [host] if Socket::IPAddress.valid_v4?(host) || Socket::IPAddress.valid_v6?(host)
      out = [] of String
      begin
        Socket::Addrinfo.resolve(host, 80, type: Socket::Type::STREAM) do |info|
          out << info.ip_address.address
        end
      rescue
        # fall through with empty list; caller raises Rejected
      end
      out
    end

    private def self.private_or_local?(addr : String) : Bool
      if addr.includes?(':')
        ipv6_blocked?(addr)
      else
        ipv4_blocked?(addr)
      end
    end

    # Block 0.0.0.0/8, 10/8, 100.64/10 (CGNAT), 127/8, 169.254/16, 172.16/12,
    # 192.168/16, 224/4 (multicast), 240/4 (reserved / broadcast).
    private def self.ipv4_blocked?(addr : String) : Bool
      parts = addr.split('.')
      return false unless parts.size == 4
      bytes = parts.map(&.to_i32?)
      return false if bytes.any?(&.nil?)
      a = bytes[0].not_nil!
      b = bytes[1].not_nil!
      return true if a == 0
      return true if a == 10
      return true if a == 127
      return true if a == 169 && b == 254
      return true if a == 172 && b >= 16 && b <= 31
      return true if a == 192 && b == 168
      return true if a == 100 && b >= 64 && b <= 127
      return true if a >= 224
      false
    end

    # Conservative: only global unicast 2000::/3 is allowed.
    private def self.ipv6_blocked?(addr : String) : Bool
      normalized = addr.downcase
      first = normalized[0]?
      return true unless first
      !(first == '2' || first == '3')
    end
  end
end
