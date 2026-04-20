require "http/client"
require "uri/params"
require "json"
require "base64"
require "openssl/hmac"
require "random/secure"

module CronLord
  module Auth
    # GitHub OAuth session management. No shard needed — stdlib HTTP::Client
    # handles both the code exchange and user-info fetch. Sessions are signed
    # HMAC-SHA256 cookies so the server stays stateless.
    extend self

    SESSION_COOKIE = "cl_sess"
    STATE_COOKIE   = "cl_state"
    SESSION_TTL    = 7 * 24 * 3600

    struct Session
      getter login : String
      getter id : Int64
      getter avatar : String

      def initialize(@login : String, @id : Int64, @avatar : String)
      end
    end

    # Build the GitHub OAuth authorize URL with required params.
    def authorize_url(client_id : String, redirect_uri : String, state : String) : String
      params = URI::Params.encode({
        "client_id"    => client_id,
        "redirect_uri" => redirect_uri,
        "scope"        => "read:user",
        "state"        => state,
      })
      "https://github.com/login/oauth/authorize?#{params}"
    end

    # Exchange an authorization code for an access token.
    # Returns nil on any network or protocol failure — callers must handle.
    def exchange_code(client_id : String, client_secret : String,
                      code : String, redirect_uri : String) : String?
      body = URI::Params.encode({
        "client_id"     => client_id,
        "client_secret" => client_secret,
        "code"          => code,
        "redirect_uri"  => redirect_uri,
      })
      client = HTTP::Client.new("github.com", tls: true)
      client.connect_timeout = 10.seconds
      client.read_timeout = 15.seconds
      resp = client.post(
        "/login/oauth/access_token",
        headers: HTTP::Headers{
          "Accept"       => "application/json",
          "Content-Type" => "application/x-www-form-urlencoded",
        },
        body: body
      )
      return nil unless resp.status.success?
      JSON.parse(resp.body)["access_token"]?.try(&.as_s?)
    rescue
      nil
    end

    # Fetch the authenticated user's profile from api.github.com.
    # Returns nil on any failure; callers surface a 502.
    def fetch_user(token : String) : Session?
      client = HTTP::Client.new("api.github.com", tls: true)
      client.connect_timeout = 10.seconds
      client.read_timeout = 15.seconds
      resp = client.get(
        "/user",
        headers: HTTP::Headers{
          "Authorization" => "Bearer #{token}",
          "Accept"        => "application/vnd.github+json",
          "User-Agent"    => "CronLord/#{CronLord::VERSION}",
        }
      )
      return nil unless resp.status.success?
      j = JSON.parse(resp.body)
      login = j["login"]?.try(&.as_s?) || return nil
      id = j["id"]?.try(&.as_i64?) || return nil
      avatar = j["avatar_url"]?.try(&.as_s?) || ""
      Session.new(login, id, avatar)
    rescue
      nil
    end

    # Encode a session as a signed cookie value.
    # Format: <base64url_json>.<hmac_hex>
    # The HMAC covers only the encoded payload, not the separator.
    def encode_session(session : Session, secret : String) : String
      exp = Time.utc.to_unix + SESSION_TTL
      payload = {
        "login"  => session.login,
        "id"     => session.id,
        "avatar" => session.avatar,
        "exp"    => exp,
      }.to_json
      encoded = Base64.urlsafe_encode(payload, padding: false)
      sig = OpenSSL::HMAC.hexdigest(:sha256, secret, encoded)
      "#{encoded}.#{sig}"
    end

    # Decode and verify a session cookie. Returns nil if the signature is
    # wrong, the base64 is malformed, or the session has expired.
    # Uses rpartition so the payload itself can contain a dot.
    def decode_session(cookie : String, secret : String) : Session?
      parts = cookie.rpartition(".")
      # rpartition returns {"", "", original} when the separator is absent
      return nil if parts[1].empty?
      encoded = parts[0]
      sig = parts[2]
      expected = OpenSSL::HMAC.hexdigest(:sha256, secret, encoded)
      # Constant-time compare is the correct choice here; session hijacking
      # via timing oracle is a real attack class. The HMAC strings are the
      # same length so constant_time_compare works correctly.
      return nil unless Crypto::Subtle.constant_time_compare(expected, sig)
      payload = JSON.parse(Base64.decode_string(encoded))
      exp = payload["exp"]?.try(&.as_i64?) || return nil
      return nil if Time.utc.to_unix > exp
      login = payload["login"]?.try(&.as_s?) || return nil
      id = payload["id"]?.try(&.as_i64?) || return nil
      avatar = payload["avatar"]?.try(&.as_s?) || ""
      Session.new(login, id, avatar)
    rescue
      nil
    end

    def random_state : String
      Random::Secure.hex(16)
    end
  end
end
