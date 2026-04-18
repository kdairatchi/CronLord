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
    property worker_id : String? = nil
    property lease_expires_at : Int64? = nil
    property heartbeat_at : Int64? = nil

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

    COLUMNS = "id,job_id,status,started_at,finished_at,exit_code,attempt,log_path," \
              "trigger,error,worker_id,lease_expires_at,heartbeat_at"

    SELECT_SQL = "SELECT " + COLUMNS + " FROM runs"
    SELECT_BY_ID_SQL = "SELECT " + COLUMNS + " FROM runs WHERE id = ?"

    def self.recent(job_id : String? = nil, limit : Int32 = 100, db = DB.conn) : Array(Run)
      out = [] of Run
      sql = recent_sql(job_id != nil)
      args = [] of ::DB::Any
      args << job_id if job_id
      args << limit
      db.query_each(sql, args: args) { |rs| out << hydrate(rs) }
      out
    end

    def self.find(id : String, db = DB.conn) : Run?
      db.query_one?(SELECT_BY_ID_SQL, id) { |rs| hydrate(rs) }
    end

    private def self.recent_sql(filter_by_job : Bool) : String
      base = SELECT_SQL
      base += " WHERE job_id = ?" if filter_by_job
      base += " ORDER BY COALESCE(started_at, 0) DESC LIMIT ?"
      base
    end

    LEASE_PICK_PREFIX = "SELECT id FROM runs WHERE status='queued' AND worker_id IS NULL AND job_id IN ("
    LEASE_PICK_SUFFIX = ") ORDER BY COALESCE(started_at, 0) ASC, id ASC LIMIT 1"

    private def self.build_lease_pick_sql(count : Int32) : String
      String.build do |io|
        io << LEASE_PICK_PREFIX
        count.times do |i|
          io << ',' if i > 0
          io << '?'
        end
        io << LEASE_PICK_SUFFIX
      end
    end

    # Atomically lease the oldest queued run that matches this worker. The
    # UPDATE is the lease acquire; the subsequent SELECT returns the row we
    # just claimed. sqlite doesn't support RETURNING in every distribution
    # so we read back explicitly.
    def self.try_lease!(worker_id : String, lease_sec : Int32, candidate_ids : Array(String),
                        db = DB.conn) : Run?
      return nil if candidate_ids.empty?
      expires = Time.utc.to_unix + lease_sec
      now = Time.utc.to_unix
      # Pick the oldest unassigned queued run whose job is in the candidate set.
      lease_sql = build_lease_pick_sql(candidate_ids.size)
      row_id = db.query_one?(
        lease_sql,
        args: candidate_ids.map { |id| id.as(::DB::Any) }
      ) { |rs| rs.read(String) }
      return nil unless row_id

      updated = db.exec(
        "UPDATE runs SET worker_id=?, lease_expires_at=?, heartbeat_at=?, status='running', started_at=? " \
        "WHERE id=? AND status='queued' AND worker_id IS NULL",
        worker_id, expires, now, now, row_id).rows_affected
      return nil if updated == 0
      find(row_id, db)
    end

    def heartbeat!(lease_sec : Int32, db = DB.conn) : Nil
      now = Time.utc.to_unix
      @heartbeat_at = now
      @lease_expires_at = now + lease_sec
      db.exec(
        "UPDATE runs SET heartbeat_at=?, lease_expires_at=? WHERE id=? AND worker_id=?",
        @heartbeat_at, @lease_expires_at, @id, @worker_id)
    end

    # Worker reports a terminal status. Clears lease columns so the reaper
    # doesn't try to re-queue a finished run.
    def finish_from_worker!(status : String, exit_code : Int32?, error : String?,
                            db = DB.conn) : Nil
      @status = status
      @exit_code = exit_code
      @error = error
      @finished_at = Time.utc.to_unix
      @lease_expires_at = nil
      db.exec(
        "UPDATE runs SET status=?, finished_at=?, exit_code=?, error=?, lease_expires_at=NULL " \
        "WHERE id=?",
        status, @finished_at, exit_code, error, @id)
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
      r.worker_id = rs.read(String?)
      r.lease_expires_at = rs.read(Int64?)
      r.heartbeat_at = rs.read(Int64?)
      r
    end
  end
end
