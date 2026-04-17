require "json"
require "toml"

module CronLord
  # Runtime configuration loaded from cronlord.toml + environment overrides.
  struct Config
    getter listen_host : String
    getter listen_port : Int32
    getter data_dir : String
    getter db_path : String
    getter log_dir : String
    getter admin_token : String?
    getter file_jobs : Array(FileJob)

    DEFAULT_PATH = "cronlord.toml"

    struct FileJob
      include ::JSON::Serializable
      property id : String
      property name : String
      property schedule : String
      property command : String
      property kind : String = "shell"
      property enabled : Bool = true
      property category : String = "default"
      property timeout_sec : Int32 = 0
      property max_concurrent : Int32 = 1
      property timezone : String = "UTC"

      def initialize(@id, @name, @schedule, @command, @kind = "shell",
                     @enabled = true, @category = "default",
                     @timeout_sec = 0, @max_concurrent = 1, @timezone = "UTC")
      end
    end

    def initialize(@listen_host, @listen_port, @data_dir, @db_path, @log_dir,
                   @admin_token, @file_jobs)
    end

    def self.load(path : String = DEFAULT_PATH) : Config
      doc = if File.exists?(path)
              TOML.parse_file(path)
            else
              TOML::Table.new
            end

      server = doc["server"]?.try(&.as_h?) || TOML::Table.new
      storage = doc["storage"]?.try(&.as_h?) || TOML::Table.new

      # Precedence: env > toml > default. Env wins so operators can override
      # without editing config files.
      host = ENV["CRONLORD_HOST"]? || server["host"]?.try(&.as_s?) || "127.0.0.1"
      port = ENV["CRONLORD_PORT"]?.try(&.to_i32) || server["port"]?.try(&.as_i?) || 7070
      data_dir = ENV["CRONLORD_DATA"]? || storage["data_dir"]?.try(&.as_s?) || "var"
      db_path = ENV["CRONLORD_DB"]? || storage["db_path"]?.try(&.as_s?) || File.join(data_dir, "cronlord.db")
      log_dir = ENV["CRONLORD_LOG_DIR"]? || storage["log_dir"]?.try(&.as_s?) || File.join(data_dir, "logs")
      admin_token = ENV["CRONLORD_ADMIN_TOKEN"]? || server["admin_token"]?.try(&.as_s?)

      jobs = parse_file_jobs(doc["jobs"]?)

      Config.new(
        listen_host: host,
        listen_port: port.to_i32,
        data_dir: data_dir,
        db_path: db_path,
        log_dir: log_dir,
        admin_token: admin_token,
        file_jobs: jobs,
      )
    end

    private def self.parse_file_jobs(raw : TOML::Any?) : Array(FileJob)
      return [] of FileJob if raw.nil?
      array = raw.as_a? || return [] of FileJob
      array.compact_map do |entry|
        h = entry.as_h? || next
        id = h["id"]?.try(&.as_s?)
        name = h["name"]?.try(&.as_s?) || id
        schedule = h["schedule"]?.try(&.as_s?)
        command = h["command"]?.try(&.as_s?)
        next unless id && name && schedule && command
        FileJob.new(
          id: id,
          name: name,
          schedule: schedule,
          command: command,
          kind: h["kind"]?.try(&.as_s?) || "shell",
          enabled: h["enabled"]?.try(&.as_bool?).nil? ? true : h["enabled"].as_bool,
          category: h["category"]?.try(&.as_s?) || "default",
          timeout_sec: h["timeout_sec"]?.try(&.as_i?) || 0,
          max_concurrent: h["max_concurrent"]?.try(&.as_i?) || 1,
          timezone: h["timezone"]?.try(&.as_s?) || "UTC",
        )
      end
    end
  end
end
