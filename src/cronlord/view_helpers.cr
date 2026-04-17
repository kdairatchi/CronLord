module CronLord
  module ViewHelpers
    extend self

    def status_class(status : String) : String
      case status
      when "success"                 then "ok"
      when "running", "queued"       then "info"
      when "fail", "timeout"         then "fail"
      when "cancelled"               then "warn"
      else                                "mute"
      end
    end

    def duration_for(run : Run) : String
      s = run.started_at
      return "—" unless s
      finish = run.finished_at || Time.utc.to_unix
      format_duration(finish - s)
    end

    def format_duration(total_seconds : Int64) : String
      return "#{total_seconds}s" if total_seconds < 60
      minutes = total_seconds // 60
      seconds = total_seconds % 60
      return "#{minutes}m #{seconds}s" if minutes < 60
      hours = minutes // 60
      mins = minutes % 60
      "#{hours}h #{mins}m"
    end

    def theme_from(env) : String
      # Placeholder — real preference is stored in localStorage by the layout
      # script. Server-side default respects `data-theme` attr for SSR.
      "light"
    end

    def action_class(action : String) : String
      case action
      when .ends_with?(".delete")  then "fail"
      when .ends_with?(".create")  then "ok"
      when .ends_with?(".update")  then "info"
      when .ends_with?(".run")     then "info"
      else                              "mute"
      end
    end

    def meta_summary(entry : Audit) : String
      return "" if entry.meta.empty?
      entry.meta.map { |k, v|
        val = v.as_s? || v.as_i64?.try(&.to_s) || v.to_json
        "#{k}=#{val}"
      }.join(" · ")
    end
  end
end
