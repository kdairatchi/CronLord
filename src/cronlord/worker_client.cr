require "http/client"
require "json"
require "uri"
require "./auth/hmac"

module CronLord
  # HTTP client used by the reference worker to talk to the scheduler.
  # Signs every request with HMAC-SHA256 over "timestamp\nbody" using the
  # locally-derived HMAC key (= sha256 of the plaintext secret).
  class WorkerClient
    class Error < Exception
    end

    # Raised by `heartbeat` when the scheduler responds with 410 - the run
    # was cancelled by an operator and the worker should abort execution.
    class CancelledError < Error
    end

    # Server returned no run - lease endpoint's 204 case. Not an error.
    NO_LEASE = :no_lease

    record LeaseResponse, run_id : String, job : JSON::Any, lease_expires_at : Int64?, heartbeat_every : Int32

    getter base : URI

    def initialize(base_url : String, @worker_id : String, @hmac_key : String)
      @base = URI.parse(base_url)
    end

    def lease(lease_sec : Int32) : LeaseResponse?
      body = {lease_sec: lease_sec}.to_json
      status, payload = post_signed("/api/workers/lease", body)
      case status
      when 204 then nil
      when 200 then parse_lease(payload)
      else          raise Error.new("lease: HTTP #{status} #{payload}")
      end
    end

    def heartbeat(run_id : String, lease_sec : Int32) : Int64?
      body = {run_id: run_id, lease_sec: lease_sec}.to_json
      status, payload = post_signed("/api/workers/heartbeat", body)
      raise CancelledError.new("run #{run_id} cancelled by operator") if status == 410
      raise Error.new("heartbeat: HTTP #{status} #{payload}") unless status == 200
      JSON.parse(payload)["lease_expires_at"]?.try(&.as_i64?)
    end

    def finish(run_id : String, status : String, exit_code : Int32?, error : String?, log : String) : Nil
      body = {
        run_id:    run_id,
        status:    status,
        exit_code: exit_code,
        error:     error,
        log:       log,
      }.to_json
      st, payload = post_signed("/api/workers/finish", body)
      raise Error.new("finish: HTTP #{st} #{payload}") unless st == 200
    end

    private def post_signed(path : String, body : String) : {Int32, String}
      ts = Time.utc.to_unix
      sig = Auth::Hmac.digest_for(@hmac_key, ts, body)
      headers = HTTP::Headers{
        "Content-Type"         => "application/json",
        "X-CronLord-Worker-Id" => @worker_id,
        "X-CronLord-Timestamp" => ts.to_s,
        "X-CronLord-Signature" => sig,
      }
      url = @base.resolve(path)
      response = HTTP::Client.post(url.to_s, headers: headers, body: body)
      {response.status_code, response.body.to_s}
    end

    private def parse_lease(payload : String) : LeaseResponse
      json = JSON.parse(payload)
      LeaseResponse.new(
        run_id: json["run_id"].as_s,
        job: json["job"],
        lease_expires_at: json["lease_expires_at"]?.try(&.as_i64?),
        heartbeat_every: json["heartbeat_every"]?.try(&.as_i?) || 30,
      )
    end
  end
end
