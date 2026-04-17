require "json"
require "uuid"

module CronLord
  enum RunStatus
    Queued
    Running
    Success
    Fail
    Timeout
    Cancelled

    def self.from_s(s : String) : RunStatus
      parse(s.camelcase)
    rescue
      Queued
    end

    def to_s_lower : String
      to_s.downcase
    end
  end

  class Run
    include JSON::Serializable

    property id : String
    property job_id : String
    property status : String
    property started_at : Int64? = nil
    property finished_at : Int64? = nil
    property exit_code : Int32? = nil
    property attempt : Int32 = 1
    property log_path : String
    property trigger : String = "schedule"
    property error : String? = nil

    def initialize(@id, @job_id, @status, @log_path)
    end

    def self.new_id : String
      UUID.random.to_s
    end

    def self.create(job_id : String, log_path : String, trigger : String = "schedule",
                    db = DB.conn) : Run
      id = new_id
      db.exec(
        "INSERT INTO runs (id, job_id, status, log_path, trigger, attempt) VALUES (?,?,?,?,?,?)",
        id, job_id, "queued", log_path, trigger, 1)
      r = Run.new(id, job_id, "queued", log_path)
      r.trigger = trigger
      r
    end

    def mark_started(db = DB.conn) : Nil
      @status = "running"
      @started_at = Time.utc.to_unix
      db.exec("UPDATE runs SET status=?, started_at=? WHERE id=?", @status, @started_at, @id)
    end

    def mark_finished(status : String, exit_code : Int32?, error : String? = nil, db = DB.conn) : Nil
      @status = status
      @exit_code = exit_code
      @error = error
      @finished_at = Time.utc.to_unix
      db.exec("UPDATE runs SET status=?, finished_at=?, exit_code=?, error=? WHERE id=?",
        status, @finished_at, exit_code, error, @id)
    end

    def self.recent(job_id : String? = nil, limit : Int32 = 100, db = DB.conn) : Array(Run)
      out = [] of Run
      sql = "SELECT id,job_id,status,started_at,finished_at,exit_code,attempt,log_path,trigger,error FROM runs"
      sql += " WHERE job_id = ?" if job_id
      sql += " ORDER BY COALESCE(started_at, 0) DESC LIMIT ?"
      args = [] of ::DB::Any
      args << job_id if job_id
      args << limit
      db.query_each(sql, args: args) { |rs| out << hydrate(rs) }
      out
    end

    private def self.hydrate(rs) : Run
      r = Run.new(
        id: rs.read(String),
        job_id: rs.read(String),
        status: rs.read(String),
        log_path: "",
      )
      r.started_at = rs.read(Int64?)
      r.finished_at = rs.read(Int64?)
      r.exit_code = rs.read(Int32 | Int64 | Nil).try(&.to_i32)
      r.attempt = rs.read(Int32 | Int64).to_i32
      r.log_path = rs.read(String)
      r.trigger = rs.read(String)
      r.error = rs.read(String?)
      r
    end
  end
end
