require "http/client"
require "json"
require "uri"

module CronLord
  # Best-effort outbound delivery when a run finishes. Two channels:
  #   - Generic webhook (job.args["webhook_url"]): JSON payload with run details.
  #   - Slack webhook (job.args["slack_webhook_url"]): Block Kit message.
  # Failures are logged but never bubble up — the scheduler must not stall.
  module Notifier
    DEFAULT_TIMEOUT  = 5
    MAX_ATTEMPTS     = 3
    RETRY_SPACING    = 2.seconds
    SLACK_URL_PREFIX = "https://hooks.slack.com/"

    def self.deliver(job : Job, run : Run) : Nil
      deliver_webhook(job, run)
      deliver_slack(job, run)
    end

    def self.deliver_webhook(job : Job, run : Run) : Nil
      url = job.args["webhook_url"]?.try(&.as_s?)
      return unless url && !url.empty?

      body = webhook_payload(job, run).to_json
      spawn post_with_retry(url, body, job.id, "webhook")
    end

    def self.deliver_slack(job : Job, run : Run) : Nil
      url = job.args["slack_webhook_url"]?.try(&.as_s?)
      return unless url && !url.empty?
      unless url.starts_with?(SLACK_URL_PREFIX)
        STDERR.puts "[notifier] refusing non-Slack URL in slack_webhook_url for job=#{job.id}"
        return
      end

      body = slack_payload(job, run).to_json
      spawn post_with_retry(url, body, job.id, "slack")
    end

    def self.webhook_payload(job : Job, run : Run)
      {
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
    end

    # Slack Block Kit payload. Status uses `[ok]`/`[fail]`/`[timeout]` tags — no emoji.
    def self.slack_payload(job : Job, run : Run)
      tag = status_tag(run.status)
      summary = "#{tag} #{job.name}"
      duration = if (s = run.started_at) && (f = run.finished_at)
                   "#{f - s}s"
                 else
                   "—"
                 end
      exit_code = run.exit_code.nil? ? "—" : run.exit_code.to_s

      blocks = [
        JSON.parse({
          "type" => "section",
          "text" => {"type" => "mrkdwn", "text" => "*#{summary}*\n`#{job.id}` · run `#{run.id}`"},
        }.to_json),
        JSON.parse({
          "type"   => "section",
          "fields" => [
            {"type" => "mrkdwn", "text" => "*Status:*\n#{run.status}"},
            {"type" => "mrkdwn", "text" => "*Trigger:*\n#{run.trigger}"},
            {"type" => "mrkdwn", "text" => "*Duration:*\n#{duration}"},
            {"type" => "mrkdwn", "text" => "*Exit:*\n#{exit_code}"},
          ],
        }.to_json),
      ]

      error = run.error
      if error && !error.empty?
        blocks << JSON.parse({
          "type" => "section",
          "text" => {"type" => "mrkdwn", "text" => "*Error:*\n```#{truncate(error, 500)}```"},
        }.to_json)
      end

      {"text" => summary, "blocks" => blocks}
    end

    def self.status_tag(status : String) : String
      case status
      when "success"   then "[ok]"
      when "fail"      then "[fail]"
      when "timeout"   then "[timeout]"
      when "cancelled" then "[cancelled]"
      else                  "[#{status}]"
      end
    end

    private def self.truncate(s : String, limit : Int32) : String
      s.size <= limit ? s : "#{s[0, limit]}…"
    end

    private def self.post_with_retry(url : String, body : String, job_id : String, channel : String) : Nil
      attempt = 0
      loop do
        attempt += 1
        if try_post(url, body)
          return
        end
        break if attempt >= MAX_ATTEMPTS
        sleep RETRY_SPACING
      end
      STDERR.puts "[notifier] giving up on #{channel} for job=#{job_id} after #{MAX_ATTEMPTS} attempts"
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
