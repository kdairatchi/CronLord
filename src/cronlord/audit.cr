require "json"

module CronLord
  # Append-only audit trail. Every mutating API action writes one row so
  # an operator can explain what changed, by whom, and when.
  class Audit
    include JSON::Serializable

    property id : Int64
    property at : Int64
    property actor : String
    property action : String
    property target : String?
    property meta : Hash(String, JSON::Any)

    def initialize(@id, @at, @actor, @action, @target, @meta)
    end

    def self.write(action : String, actor : String = "system",
                   target : String? = nil, meta : Hash(String, JSON::Any) = {} of String => JSON::Any,
                   db = DB.conn) : Nil
      db.exec(
        "INSERT INTO audit (at, actor, action, target, meta_json) VALUES (?,?,?,?,?)",
        Time.utc.to_unix, actor, action, target, meta.to_json)
    rescue ex
      STDERR.puts "[audit] failed: #{ex.class}: #{ex.message}"
    end

    def self.recent(limit : Int32 = 200, db = DB.conn) : Array(Audit)
      out = [] of Audit
      db.query_each(
        "SELECT id, at, actor, action, target, meta_json FROM audit ORDER BY at DESC LIMIT ?",
        limit
      ) { |rs| out << hydrate(rs) }
      out
    end

    def at_time : Time
      Time.unix(@at)
    end

    private def self.hydrate(rs) : Audit
      id = rs.read(Int32 | Int64).to_i64
      at = rs.read(Int64)
      actor = rs.read(String)
      action = rs.read(String)
      target = rs.read(String?)
      raw = rs.read(String)
      meta = raw.empty? ? ({} of String => JSON::Any) : JSON.parse(raw).as_h
      Audit.new(id, at, actor, action, target, meta)
    rescue JSON::ParseException
      id = rs.read(Int32 | Int64).to_i64
      Audit.new(id, 0_i64, "system", "parse-error", nil, {} of String => JSON::Any)
    end
  end
end
