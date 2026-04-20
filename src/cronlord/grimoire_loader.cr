require "toml"

module CronLord
  module GrimoireLoader
    record Ritual,
      id : String,
      name : String,
      description : String,
      category : String,
      schedule : String,
      command : String,
      kind : String,
      enabled : Bool,
      timezone : String,
      timeout_sec : Int32,
      file_path : String # relative path within grimoire/rituals/

    def self.rituals_dir(grimoire_path : String) : String
      File.join(grimoire_path, "rituals")
    end

    def self.present?(grimoire_path : String?) : Bool
      return false unless grimoire_path
      Dir.exists?(rituals_dir(grimoire_path))
    end

    # Returns rituals grouped by category, sorted by category then name.
    def self.load(grimoire_path : String) : Hash(String, Array(Ritual))
      rdir = rituals_dir(grimoire_path)
      result = {} of String => Array(Ritual)

      Dir.glob("#{rdir}/**/*.toml").sort.each do |full_path|
        ritual = parse_file(full_path, rdir) rescue next
        next unless ritual
        (result[ritual.category] ||= [] of Ritual) << ritual
      end

      result.each_value(&.sort_by!(&.name.downcase))
      result.to_a.sort_by { |k, _| k }.to_h
    end

    def self.load_one(grimoire_path : String, rel_path : String) : Ritual?
      rdir = File.expand_path(rituals_dir(grimoire_path))
      full = File.expand_path(File.join(rdir, rel_path))
      # path traversal guard
      return nil unless full.starts_with?(rdir + File::SEPARATOR)
      return nil unless File.exists?(full)
      parse_file(full, rdir)
    end

    private def self.parse_file(full_path : String, rdir : String) : Ritual?
      rel = full_path.sub(rdir + File::SEPARATOR, "")
      doc = TOML.parse_file(full_path)
      jobs = doc["jobs"]?.try(&.as_a?) || return nil
      entry = jobs.first?.try(&.as_h?) || return nil

      id = entry["id"]?.try(&.as_s?) || return nil
      name = entry["name"]?.try(&.as_s?) || id
      schedule = entry["schedule"]?.try(&.as_s?) || return nil
      command = entry["command"]?.try(&.as_s?) || return nil

      Ritual.new(
        id: id,
        name: name,
        description: entry["description"]?.try(&.as_s?) || "",
        category: entry["category"]?.try(&.as_s?) ||
                  rel.split(File::SEPARATOR).first? || "default",
        schedule: schedule,
        command: command,
        kind: entry["kind"]?.try(&.as_s?) || "shell",
        enabled: entry["enabled"]?.try(&.as_bool?) || false,
        timezone: entry["timezone"]?.try(&.as_s?) || "UTC",
        timeout_sec: entry["timeout_sec"]?.try(&.as_i?) || 0,
        file_path: rel,
      )
    end
  end
end
