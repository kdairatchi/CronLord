require "http/client"
require "json"
require "uri"

module CronLord
  # Best-effort HTTP webhook delivery when a run finishes.
  # Each job can carry a webhook URL in `job.args["webhook_url"]` (string).
  # Failures are logged but never bubbled up — the scheduler must not stall.
  module Notifier
    DEFAULT_TIMEOUT = 5
    MAX_ATTEMPTS    = 3
    RETRY_SPACING   = 2.seconds

    def self.deliver(job : Job, run : Run) : Nil
      url = job.args["webhook_url"]?.try(&.as_s?)
      return unless url && !url.empty?

      payload = {
        "job_id"      => job.id,
        "job_name"    => job.name,
        "run_id"      => run.id,
        "status"      => run.status,
        "trigger"     => run.trigger,
        "exit_code"   => run.exit_code,
        "started_at"  => run.started_at,
        "finished_at" => run.finished_at,
        "error"       => run.error,
      }
      body = payload.to_json
      spawn post_with_retry(url, body, job.id)
    end

    private def self.post_with_retry(url : String, body : String, job_id : String) : Nil
      attempt = 0
      loop do
        attempt += 1
        if try_post(url, body)
          return
        end
        break if attempt >= MAX_ATTEMPTS
        sleep RETRY_SPACING
      end
      STDERR.puts "[notifier] giving up on webhook for job=#{job_id} after #{MAX_ATTEMPTS} attempts"
    end

    private def self.try_post(url : String, body : String) : Bool
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = DEFAULT_TIMEOUT.seconds
      client.read_timeout = DEFAULT_TIMEOUT.seconds
      client.write_timeout = DEFAULT_TIMEOUT.seconds
      headers = HTTP::Headers{
        "Content-Type" => "application/json",
        "User-Agent"   => "CronLord/#{VERSION} (notifier)",
      }
      path = uri.path.empty? ? "/" : uri.path
      path = "#{path}?#{uri.query}" if (q = uri.query) && !q.empty?
      response = client.post(path, headers: headers, body: body)
      response.status_code >= 200 && response.status_code < 300
    rescue ex
      STDERR.puts "[notifier] attempt failed: #{ex.class}: #{ex.message}"
      false
    end
  end
end
