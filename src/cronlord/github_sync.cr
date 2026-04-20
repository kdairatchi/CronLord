require "http/client"
require "json"
require "toml"
require "uri"

module CronLord
  module GithubSync
    extend self

    LOG = ::Log.for("cronlord.github_sync")

    class Error < Exception; end

    struct Result
      include JSON::Serializable

      getter imported : Int32
      getter updated : Int32
      getter errors : Array(String)
      getter synced_at : Int64

      def initialize(@imported, @updated, @errors, @synced_at = Time.utc.to_unix)
      end

      def ok? : Bool
        @errors.empty?
      end

      def total : Int32
        @imported + @updated
      end
    end

    # Fetch the remote file and upsert every job into the DB.
    # Returns a Result describing what happened.
    def sync(cfg : Config) : Result
      gh = cfg.github
      unless gh.configured?
        return Result.new(imported: 0, updated: 0, errors: ["github not configured"])
      end

      repo   = gh.repo.not_nil!
      branch = gh.branch
      path   = gh.path

      body, fetch_err = fetch_content(repo, branch, path, gh.token)
      if fetch_err
        return Result.new(imported: 0, updated: 0, errors: [fetch_err])
      end

      raw_body = body.not_nil!
      jobs, parse_errors = parse_jobs(raw_body, path)

      imported = 0
      updated  = 0

      jobs.each do |fj|
        existed = Job.find(fj.id)
        job = existed || Job.new(fj.id, fj.name, fj.kind, fj.schedule, fj.command)
        job.name          = fj.name
        job.kind          = fj.kind
        job.schedule      = fj.schedule
        job.command       = fj.command
        job.enabled       = fj.enabled
        job.category      = fj.category
        job.timeout_sec   = fj.timeout_sec
        job.max_concurrent = fj.max_concurrent
        job.timezone      = fj.timezone
        job.source        = "github"
        begin
          job.upsert
          if existed
            updated += 1
          else
            imported += 1
          end
          Audit.write(
            existed ? "job.update" : "job.create",
            actor:  "github_sync",
            target: "job:#{job.id}",
            meta:   {"name" => JSON::Any.new(job.name), "repo" => JSON::Any.new(repo)},
          )
        rescue ex
          parse_errors << "upsert #{fj.id}: #{ex.message}"
        end
      end

      Result.new(imported: imported, updated: updated, errors: parse_errors)
    end

    # Retrieve raw file content from GitHub.
    # When a PAT is present, uses the REST contents API (works for private repos).
    # Without a token, uses raw.githubusercontent.com (public only).
    private def fetch_content(repo : String, branch : String, path : String,
                              token : String?) : {String?, String?}
      if token
        fetch_via_api(repo, branch, path, token)
      else
        fetch_via_raw(repo, branch, path)
      end
    end

    private def fetch_via_api(repo : String, branch : String, path : String,
                              token : String) : {String?, String?}
      url = "https://api.github.com/repos/#{repo}/contents/#{path}?ref=#{branch}"
      begin
        uri    = URI.parse(url)
        client = HTTP::Client.new(host: "api.github.com", port: 443, tls: true)
        client.connect_timeout = 15.seconds
        client.read_timeout    = 15.seconds
        headers = HTTP::Headers{
          "Authorization" => "Bearer #{token}",
          "Accept"        => "application/vnd.github.raw+json",
          "User-Agent"    => "CronLord/#{CronLord::VERSION}",
        }
        request_path = uri.path
        request_path += "?ref=#{branch}"
        resp = client.get(request_path, headers: headers)
        if resp.status_code == 200
          {resp.body, nil}
        else
          {nil, "GitHub API returned #{resp.status_code} for #{repo}/#{path}@#{branch}"}
        end
      rescue ex
        {nil, "fetch error: #{ex.message}"}
      end
    end

    private def fetch_via_raw(repo : String, branch : String, path : String) : {String?, String?}
      url = "https://raw.githubusercontent.com/#{repo}/#{branch}/#{path}"
      begin
        uri    = URI.parse(url)
        client = HTTP::Client.new(host: "raw.githubusercontent.com", port: 443, tls: true)
        client.connect_timeout = 15.seconds
        client.read_timeout    = 15.seconds
        headers = HTTP::Headers{"User-Agent" => "CronLord/#{CronLord::VERSION}"}
        req_path = uri.path
        resp = client.get(req_path, headers: headers)
        if resp.status_code == 200
          {resp.body, nil}
        else
          {nil, "raw.githubusercontent.com returned #{resp.status_code} for #{repo}/#{path}@#{branch}"}
        end
      rescue ex
        {nil, "fetch error: #{ex.message}"}
      end
    end

    # Parse the fetched content as TOML and extract [[jobs]] entries.
    # Returns {jobs, errors}.
    private def parse_jobs(body : String, path : String) : {Array(Config::FileJob), Array(String)}
      errors = [] of String
      begin
        doc    = TOML.parse(body)
        raw    = doc["jobs"]?
        if raw.nil?
          return {[] of Config::FileJob, ["no [[jobs]] entries found in #{path}"]}
        end
        jobs = Config.parse_file_jobs_public(raw)
        {jobs, errors}
      rescue ex : TOML::ParseException
        {[] of Config::FileJob, ["TOML parse error: #{ex.message}"]}
      rescue ex
        {[] of Config::FileJob, ["parse error: #{ex.message}"]}
      end
    end
  end
end
