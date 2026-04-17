require "json"
require "uuid"

module CronLord
  # In-memory representation of a scheduled job. Persistence lives in SQLite.
  struct Job
    include JSON::Serializable

    property id : String
    property name : String
    property description : String = ""
    property category : String = "default"
    property kind : String
    property schedule : String
    property timezone : String = "UTC"
    property command : String
    property args : Hash(String, JSON::Any) = {} of String => JSON::Any
    property env : Hash(String, String) = {} of String => String
    property working_dir : String? = nil
    property timeout_sec : Int32 = 0
    property max_concurrent : Int32 = 1
    property retry_count : Int32 = 0
    property retry_delay_sec : Int32 = 30
    property enabled : Bool = true
    property source : String = "api"
    property executor : String = "local"
    property labels : Array(String) = [] of String
    property created_at : Int64 = Time.utc.to_unix
    property updated_at : Int64 = Time.utc.to_unix

    def initialize(@id, @name, @kind, @schedule, @command)
    end

    def self.new_id : String
      UUID.random.to_s
    end

    def cron : Cron
      Cron.parse(@schedule)
    end

    # Resolve the job's configured timezone. Raises ArgumentError if unknown.
    def location : Time::Location
      Time::Location.load(@timezone)
    rescue Time::Location::InvalidLocationNameError
      raise ArgumentError.new("unknown timezone: #{@timezone}")
    end

    # --- persistence ---------------------------------------------------------

    COLUMNS = "id,name,description,category,kind,schedule,timezone,command," \
              "args_json,env_json,working_dir,timeout_sec,max_concurrent,retry_count," \
              "retry_delay_sec,enabled,source,executor,labels_json,created_at,updated_at"

    def self.all(db = DB.conn) : Array(Job)
      out = [] of Job
      db.query_each("SELECT #{COLUMNS} FROM jobs") { |rs| out << hydrate(rs) }
      out
    end

    def self.find(id : String, db = DB.conn) : Job?
      db.query_one?(
        "SELECT #{COLUMNS} FROM jobs WHERE id = ?", id
      ) { |rs| hydrate(rs) }
    end

    UPSERT_SQL = <<-SQL
      INSERT INTO jobs (id,name,description,category,kind,schedule,timezone,command,
        args_json,env_json,working_dir,timeout_sec,max_concurrent,retry_count,
        retry_delay_sec,enabled,source,executor,labels_json,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        name=excluded.name,
        description=excluded.description,
        category=excluded.category,
        kind=excluded.kind,
        schedule=excluded.schedule,
        timezone=excluded.timezone,
        command=excluded.command,
        args_json=excluded.args_json,
        env_json=excluded.env_json,
        working_dir=excluded.working_dir,
        timeout_sec=excluded.timeout_sec,
        max_concurrent=excluded.max_concurrent,
        retry_count=excluded.retry_count,
        retry_delay_sec=excluded.retry_delay_sec,
        enabled=excluded.enabled,
        source=excluded.source,
        executor=excluded.executor,
        labels_json=excluded.labels_json,
        updated_at=excluded.updated_at
      SQL

    def upsert(db = DB.conn) : Nil
      location # raises ArgumentError if @timezone is invalid
      @updated_at = Time.utc.to_unix
      db.exec(UPSERT_SQL,
        args: [@id, @name, @description, @category, @kind, @schedule, @timezone,
               @command, @args.to_json, @env.to_json, @working_dir, @timeout_sec,
               @max_concurrent, @retry_count, @retry_delay_sec,
               (@enabled ? 1 : 0), @source, @executor, @labels.to_json,
               @created_at, @updated_at])
    end

    def self.delete(id : String, db = DB.conn) : Bool
      db.exec("DELETE FROM jobs WHERE id = ?", id).rows_affected > 0
    end

    private def self.hydrate(rs) : Job
      j = Job.new(
        id: rs.read(String),
        name: rs.read(String),
        kind: "", schedule: "", command: "",
      )
      j.description = rs.read(String)
      j.category = rs.read(String)
      j.kind = rs.read(String)
      j.schedule = rs.read(String)
      j.timezone = rs.read(String)
      j.command = rs.read(String)
      j.args = parse_json_hash(rs.read(String))
      env_raw = parse_json_hash(rs.read(String))
      j.env = env_raw.each_with_object({} of String => String) { |(k, v), acc| acc[k] = v.as_s? || v.to_s }
      j.working_dir = rs.read(String?)
      j.timeout_sec = rs.read(Int32 | Int64).to_i32
      j.max_concurrent = rs.read(Int32 | Int64).to_i32
      j.retry_count = rs.read(Int32 | Int64).to_i32
      j.retry_delay_sec = rs.read(Int32 | Int64).to_i32
      j.enabled = rs.read(Int32 | Int64) != 0
      j.source = rs.read(String)
      j.executor = rs.read(String)
      j.labels = parse_labels_array(rs.read(String))
      j.created_at = rs.read(Int64)
      j.updated_at = rs.read(Int64)
      j
    end

    private def self.parse_json_hash(raw : String) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if raw.blank?
      JSON.parse(raw).as_h
    rescue JSON::ParseException
      {} of String => JSON::Any
    end

    private def self.parse_labels_array(raw : String) : Array(String)
      return [] of String if raw.blank?
      JSON.parse(raw).as_a.map { |v| v.as_s? || v.to_s }
    rescue JSON::ParseException
      [] of String
    end
  end
end
