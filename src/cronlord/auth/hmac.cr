require "openssl/hmac"
require "crypto/subtle"

module CronLord
  module Auth
    # HMAC-SHA256 request signing for worker APIs.
    #
    # The canonical string is "timestamp + \"\\n\" + body". Signatures are
    # transmitted hex-encoded (lowercase). Verification uses a constant-time
    # compare and enforces a ±skew window to mitigate replay.
    module Hmac
      DEFAULT_SKEW = 60_i64 # seconds

      class VerifyError < Exception
      end

      def self.sign(key : String, body : String, timestamp : Int64 = Time.utc.to_unix) : {String, Int64}
        digest = digest_for(key, timestamp, body)
        {digest, timestamp}
      end

      def self.digest_for(key : String, timestamp : Int64, body : String) : String
        payload = "#{timestamp}\n#{body}"
        OpenSSL::HMAC.hexdigest(:sha256, key, payload)
      end

      # Raises VerifyError on failure; returns true on success.
      def self.verify!(key : String, body : String, timestamp : Int64, signature : String,
                       skew : Int64 = DEFAULT_SKEW, now : Int64 = Time.utc.to_unix) : Bool
        drift = (now - timestamp).abs
        raise VerifyError.new("timestamp skew #{drift}s exceeds #{skew}s") if drift > skew

        expected = digest_for(key, timestamp, body)
        raise VerifyError.new("signature mismatch") unless Crypto::Subtle.constant_time_compare(expected, signature)
        true
      end

      def self.verify?(key : String, body : String, timestamp : Int64, signature : String,
                       skew : Int64 = DEFAULT_SKEW, now : Int64 = Time.utc.to_unix) : Bool
        verify!(key, body, timestamp, signature, skew, now)
        true
      rescue VerifyError
        false
      end
    end
  end
end
