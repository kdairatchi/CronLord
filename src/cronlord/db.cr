require "db"
require "sqlite3"

module CronLord
  module DB
    MIGRATION_DIR = File.expand_path("../../db/migrations", __DIR__)

    @@db : ::DB::Database?

    def self.open(path : String) : ::DB::Database
      parent = File.dirname(path)
      Dir.mkdir_p(parent) unless parent.empty? || Dir.exists?(parent)
      db = ::DB.open("sqlite3://#{path}?journal_mode=WAL&synchronous=NORMAL&busy_timeout=5000&foreign_keys=true")
      @@db = db
      db
    end

    def self.conn : ::DB::Database
      @@db || raise "CronLord::DB not opened; call DB.open first"
    end

    def self.close
      @@db.try(&.close)
      @@db = nil
    end

    # Apply every migration file under db/migrations whose numeric prefix
    # has not yet been recorded in schema_migrations.
    def self.migrate!(log : Bool = true)
      db = conn
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at INTEGER NOT NULL
        )
      SQL

      applied = Set(Int32).new
      db.query_each("SELECT version FROM schema_migrations") do |rs|
        applied << rs.read(Int32)
      end

      Dir.children(MIGRATION_DIR).select(&.ends_with?(".sql")).sort.each do |name|
        version = name[0, 3].to_i?
        next unless version
        next if applied.includes?(version)

        sql = File.read(File.join(MIGRATION_DIR, name))
        STDERR.puts "[migrate] #{name}" if log
        db.transaction do |tx|
          split_statements(sql).each { |stmt| tx.connection.exec(stmt) unless stmt.strip.empty? }
          tx.connection.exec("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
            version, Time.utc.to_unix)
        end
      end
    end

    # Split a multi-statement SQL file into individual statements. SQLite's
    # prepared-statement API only runs one per exec; we strip line comments
    # (including trailing `-- ...`) so semicolons inside comments cannot split
    # a statement mid-way.
    private def self.split_statements(sql : String) : Array(String)
      cleaned = sql.each_line.map { |l| strip_line_comment(l) }.reject(&.blank?).join('\n')
      cleaned.split(";").map(&.strip).reject(&.empty?)
    end

    private def self.strip_line_comment(line : String) : String
      in_single = false
      idx = nil
      line.each_char_with_index do |c, i|
        if c == '\''
          in_single = !in_single
        elsif !in_single && c == '-' && i + 1 < line.size && line[i + 1] == '-'
          idx = i
          break
        end
      end
      idx ? line[0, idx].rstrip : line
    end
  end
end
