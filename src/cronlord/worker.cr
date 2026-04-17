require "json"
require "openssl"
require "uuid"

module CronLord
  # Registered worker node. Workers authenticate via HMAC-SHA256 using the
  # shared secret set at registration (see Auth::Hmac).
  #
  # The secret itself is never stored — only a SHA-256 hash for verification.
  # At registration time the plaintext is returned once so the operator can
  # paste it into the worker's config.
  class Worker
    include JSON::Serializable

    property id : String
    property name : String
    property secret_hash : String
    property labels : Array(String) = [] of String
    property enabled : Bool = true
    property last_seen : Int64? = nil
    property created_at : Int64 = Time.utc.to_unix

    def initialize(@id, @name, @secret_hash)
    end

    def self.new_id : String
      UUID.random.to_s
    end

    # Generate a random 32-byte secret, base36 encoded for safe copy/paste.
    def self.generate_secret : String
      bytes = Random::Secure.random_bytes(32)
      bytes.hexstring
    end

    def self.hash_secret(secret : String) : String
      OpenSSL::Digest.new("SHA256").update(secret).final.hexstring
    end

    def verify_secret(secret : String) : Bool
      Crypto::Subtle.constant_time_compare(secret_hash, Worker.hash_secret(secret))
    end

    # --- persistence --------------------------------------------------------

    def self.all(db = DB.conn) : Array(Worker)
      out = [] of Worker
      db.query_each(
        "SELECT id,name,secret_hash,labels_json,enabled,last_seen,created_at " \
        "FROM workers ORDER BY created_at DESC"
      ) { |rs| out << hydrate(rs) }
      out
    end

    def self.find(id : String, db = DB.conn) : Worker?
      db.query_one?(
        "SELECT id,name,secret_hash,labels_json,enabled,last_seen,created_at " \
        "FROM workers WHERE id = ?", id
      ) { |rs| hydrate(rs) }
    end

    def self.register(name : String, labels : Array(String) = [] of String,
                      db = DB.conn) : {Worker, String}
      secret = generate_secret
      worker = Worker.new(new_id, name, hash_secret(secret))
      worker.labels = labels
      worker.upsert(db)
      {worker, secret}
    end

    def upsert(db = DB.conn) : Nil
      db.exec(
        "INSERT INTO workers (id,name,secret_hash,labels_json,enabled,last_seen,created_at) " \
        "VALUES (?,?,?,?,?,?,?) " \
        "ON CONFLICT(id) DO UPDATE SET name=excluded.name, secret_hash=excluded.secret_hash, " \
        "labels_json=excluded.labels_json, enabled=excluded.enabled, last_seen=excluded.last_seen",
        @id, @name, @secret_hash, @labels.to_json, (@enabled ? 1 : 0), @last_seen, @created_at)
    end

    def self.delete(id : String, db = DB.conn) : Bool
      db.exec("DELETE FROM workers WHERE id = ?", id).rows_affected > 0
    end

    def touch(db = DB.conn) : Nil
      @last_seen = Time.utc.to_unix
      db.exec("UPDATE workers SET last_seen = ? WHERE id = ?", @last_seen, @id)
    end

    private def self.hydrate(rs) : Worker
      id = rs.read(String)
      name = rs.read(String)
      secret_hash = rs.read(String)
      labels_raw = rs.read(String)
      enabled = rs.read(Int32 | Int64) != 0
      last_seen = rs.read(Int64?)
      created_at = rs.read(Int64)

      w = Worker.new(id, name, secret_hash)
      w.labels = parse_labels(labels_raw)
      w.enabled = enabled
      w.last_seen = last_seen
      w.created_at = created_at
      w
    end

    private def self.parse_labels(raw : String) : Array(String)
      return [] of String if raw.blank?
      JSON.parse(raw).as_a.map { |v| v.as_s? || v.to_s }
    rescue JSON::ParseException
      [] of String
    end
  end
end
