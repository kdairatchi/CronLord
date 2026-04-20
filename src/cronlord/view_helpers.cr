module CronLord
  module ViewHelpers
    extend self

    def status_class(status : String) : String
      case status
      when "success"           then "ok"
      when "running", "queued" then "info"
      when "fail", "timeout"   then "fail"
      when "cancelled"         then "warn"
      else                          "mute"
      end
    end

    def duration_for(run : Run) : String
      s = run.started_at
      return "-" unless s
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
      # Placeholder - real preference is stored in localStorage by the layout
      # script. Server-side default respects `data-theme` attr for SSR.
      "light"
    end

    def action_class(action : String) : String
      case action
      when .ends_with?(".delete") then "fail"
      when .ends_with?(".create") then "ok"
      when .ends_with?(".update") then "info"
      when .ends_with?(".run")    then "info"
      else                             "mute"
      end
    end

    def relative_time(unix : Int64?) : String
      return "never" if unix.nil?
      delta = Time.utc.to_unix - unix
      return "in the future" if delta < 0
      return "just now" if delta < 5
      return "#{delta}s ago" if delta < 60
      return "#{delta // 60}m ago" if delta < 3600
      return "#{delta // 3600}h ago" if delta < 86_400
      "#{delta // 86_400}d ago"
    end

    def worker_state(worker : Worker) : String
      return "disabled" unless worker.enabled
      return "idle" if worker.last_seen.nil?
      delta = Time.utc.to_unix - worker.last_seen.not_nil!
      return "online" if delta < 120
      return "stale" if delta < 3600
      "idle"
    end

    def worker_state_class(state : String) : String
      case state
      when "online"   then "ok"
      when "stale"    then "warn"
      when "disabled" then "fail"
      else                 "mute"
      end
    end

    def meta_summary(entry : Audit) : String
      return "" if entry.meta.empty?
      entry.meta.map { |k, v|
        val = v.as_s? || v.as_i64?.try(&.to_s) || v.to_json
        "#{k}=#{val}"
      }.join(" | ")
    end

    def category_icon_class(cat : String) : String
      case cat
      when "monitoring"           then "icon-green"
      when "security"             then "icon-red"
      when "ai", "agents"         then "icon-purple"
      when "devops", "sync"       then "icon-blue"
      when "finance", "reporting" then "icon-amber"
      when "personal", "home"     then "icon-green"
      else                             "icon-blue"
      end
    end

    def category_icon_svg(cat : String) : String
      case cat
      when "monitoring"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>)
      when "security"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>)
      when "ai", "agents"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>)
      when "devops"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>)
      when "sync", "backup"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>)
      when "finance", "reporting"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg>)
      when "content", "media"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="23 7 16 12 23 17 23 7"/><rect x="1" y="5" width="15" height="14" rx="2" ry="2"/></svg>)
      when "personal", "home"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>)
      when "data", "database"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>)
      when "communication"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>)
      when "maintenance"
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>)
      else
        %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>)
      end
    end
  end
end
