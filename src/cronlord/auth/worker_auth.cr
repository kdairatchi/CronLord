require "./hmac"

module CronLord
  module Auth
    # Worker-side HTTP auth: resolves the worker from headers, verifies the
    # HMAC signature over the raw request body, and returns the Worker.
    #
    # Request contract:
    #   X-CronLord-Worker-Id: <uuid>
    #   X-CronLord-Timestamp: <unix seconds>
    #   X-CronLord-Signature: <hex-sha256 of "timestamp\nbody">
    #
    # The worker's shared secret was issued once at registration and is
    # stored on the server only as a SHA-256 hash of the plaintext. To verify
    # HMAC we need the plaintext secret — so the worker-auth path stores
    # the plaintext in-process cache after first use. Since we only keep the
    # hash on disk, workers MUST send the plaintext once during a bootstrap
    # step (POST /api/workers/:id/verify) before any signed call.
    #
    # To keep the v0.2 protocol simple we skip that dance: the secret hash
    # itself is treated as the HMAC key. Workers sign with the *hash* of
    # their plaintext secret. install.sh ships a helper that pre-computes
    # it. This keeps a single stored credential without a handshake step.
    module WorkerAuth
      HEADER_WORKER = "X-CronLord-Worker-Id"
      HEADER_TS     = "X-CronLord-Timestamp"
      HEADER_SIG    = "X-CronLord-Signature"

      class AuthError < Exception
      end

      def self.authenticate(env, body : String) : Worker
        worker_id = env.request.headers[HEADER_WORKER]?
        raise AuthError.new("missing #{HEADER_WORKER}") unless worker_id

        ts_raw = env.request.headers[HEADER_TS]?
        raise AuthError.new("missing #{HEADER_TS}") unless ts_raw
        ts = ts_raw.to_i64? || raise AuthError.new("invalid timestamp")

        sig = env.request.headers[HEADER_SIG]?
        raise AuthError.new("missing #{HEADER_SIG}") unless sig

        worker = Worker.find(worker_id)
        raise AuthError.new("unknown worker") unless worker
        raise AuthError.new("worker disabled") unless worker.enabled

        Hmac.verify!(worker.secret_hash, body, ts, sig)
        worker.touch
        worker
      rescue ex : Hmac::VerifyError
        raise AuthError.new(ex.message || "hmac verify failed")
      end
    end
  end
end
