require "http/client"
require "json"
require "uri"

module CronLord
  module Runner
    # Executes an HTTP job. The job command is either:
    #   - a plain URL (GET, expect 2xx)
    #   - a JSON object: {method, url, headers, body, expect_status, follow}
    #
    # The response status + truncated body land in the run log; the run is
    # marked success if the status code matches `expect_status` (default 2xx).
    class Http
      MAX_BODY_BYTES  = 32_768
      DEFAULT_TIMEOUT = 30

      struct Request
        getter method : String
        getter url : String
        getter headers : Hash(String, String)
        getter body : String?
        getter expect_status : Int32?
        getter follow_redirects : Bool

        def initialize(@method, @url, @headers = {} of String => String,
                       @body = nil, @expect_status = nil, @follow_redirects = true)
        end

        def self.parse(command : String) : Request
          src = command.strip
          if src.starts_with?('{')
            parse_json(src)
          else
            new(method: "GET", url: src)
          end
        end

        private def self.parse_json(raw : String) : Request
          payload = JSON.parse(raw)
          h = payload.as_h
          url = h["url"]?.try(&.as_s?) || raise ArgumentError.new("http job: 'url' required")
          method = (h["method"]?.try(&.as_s?) || "GET").upcase
          body = h["body"]?.try { |v| v.as_s? || v.to_json }
          expect = h["expect_status"]?.try(&.as_i?)
          follow = h["follow"]?.try(&.as_bool?)
          headers = {} of String => String
          if hv = h["headers"]?
            hv.as_h.each { |k, v| headers[k] = v.as_s? || v.to_s }
          end
          new(method, url, headers, body, expect, follow.nil? ? true : follow)
        end
      end

      def self.run(job : Job, run : Run, buffer : LogBuffer) : Int32
        req = Request.parse(job.command)
        buffer.write("#{req.method} #{req.url}", :meta)

        timeout = job.timeout_sec > 0 ? job.timeout_sec : DEFAULT_TIMEOUT
        status : Int32 = 0
        body : String = ""

        uri = URI.parse(req.url)
        unless uri.scheme == "http" || uri.scheme == "https"
          msg = "http job: unsupported scheme '#{uri.scheme}'"
          buffer.write(msg, :meta)
          run.mark_finished("fail", 2, msg)
          return 2
        end

        started = Time.instant
        begin
          client = HTTP::Client.new(uri)
          client.connect_timeout = timeout.seconds
          client.read_timeout = timeout.seconds
          client.write_timeout = timeout.seconds

          headers = HTTP::Headers.new
          req.headers.each { |k, v| headers[k] = v }
          headers["User-Agent"] = "CronLord/#{VERSION}" unless headers.has_key?("User-Agent")

          response = client.exec(method: req.method, path: request_path(uri),
            headers: headers, body: req.body)

          status = response.status_code
          body = response.body? || ""
          excerpt = body.bytesize > MAX_BODY_BYTES ? body.byte_slice(0, MAX_BODY_BYTES) + "\n…truncated" : body
          elapsed = (Time.instant - started).total_milliseconds.round.to_i

          buffer.write("HTTP #{status} (#{elapsed}ms)", :meta)
          excerpt.each_line { |line| buffer.write(line, :stdout) }

          if matches_expected?(status, req.expect_status)
            run.mark_finished("success", status)
          else
            expected_label = req.expect_status ? "==#{req.expect_status}" : "2xx"
            run.mark_finished("fail", status, "status #{status} (expected #{expected_label})")
          end
          status
        rescue ex : IO::TimeoutError
          buffer.write("[timeout after #{timeout}s]", :meta)
          run.mark_finished("timeout", nil, "timeout after #{timeout}s")
          124
        rescue ex
          buffer.write("[http error] #{ex.class}: #{ex.message}", :meta)
          run.mark_finished("fail", nil, ex.message)
          1
        ensure
          buffer.close rescue nil
        end
      end

      private def self.request_path(uri : URI) : String
        p = uri.path.empty? ? "/" : uri.path
        q = uri.query
        q && !q.empty? ? "#{p}?#{q}" : p
      end

      private def self.matches_expected?(actual : Int32, expected : Int32?) : Bool
        return actual >= 200 && actual < 300 if expected.nil?
        actual == expected
      end
    end
  end
end
