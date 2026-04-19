module CronLord
  # Minimal 5-field cron expression evaluator.
  #
  #   .---- minute (0-59)
  #   | .-- hour   (0-23)
  #   | | .- dom    (1-31)
  #   | | | .- month (1-12 or JAN-DEC)
  #   | | | | .- dow  (0-6, 0=SUN, or SUN-SAT)
  #   * * * * *   command
  #
  # Supported syntax: *, N, N-M, N-M/S, */S, lists (A,B), and macros
  # (@hourly @daily @weekly @monthly @yearly/@annually @midnight).
  class Cron
    class ParseError < Exception
    end

    MACROS = {
      "@hourly"   => "0 * * * *",
      "@daily"    => "0 0 * * *",
      "@midnight" => "0 0 * * *",
      "@weekly"   => "0 0 * * 0",
      "@monthly"  => "0 0 1 * *",
      "@yearly"   => "0 0 1 1 *",
      "@annually" => "0 0 1 1 *",
    }

    MONTHS = %w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
    DOWS   = %w(SUN MON TUE WED THU FRI SAT)

    getter minute : Array(Int32)
    getter hour : Array(Int32)
    getter dom : Array(Int32)
    getter month : Array(Int32)
    getter dow : Array(Int32)
    getter expr : String
    # True when either day-of-month or day-of-week was restricted (not "*").
    # Matches POSIX cron: when both are set, either matching is enough; when one is *,
    # only the restricted one applies.
    getter dom_restricted : Bool
    getter dow_restricted : Bool

    def initialize(@minute, @hour, @dom, @month, @dow, @expr, @dom_restricted, @dow_restricted)
    end

    def self.parse(expr : String) : Cron
      src = expr.strip
      raise ParseError.new("empty cron expression") if src.empty?
      src = MACROS[src.downcase]? || src
      parts = src.split(/\s+/)
      raise ParseError.new("expected 5 fields, got #{parts.size}: #{expr}") unless parts.size == 5

      minute = expand(parts[0], 0, 59)
      hour = expand(parts[1], 0, 23)
      dom = expand(parts[2], 1, 31)
      month = expand(parts[3], 1, 12, MONTHS, month_offset: 1)
      dow = expand(parts[4], 0, 7, DOWS).map { |n| n == 7 ? 0 : n }.uniq.sort!

      new(minute, hour, dom, month, dow, expr,
        dom_restricted: parts[2] != "*",
        dow_restricted: parts[4] != "*")
    end

    # Return the next `count` UTC Times strictly greater than `from` that match,
    # evaluated against the wall clock in `location` (default UTC).
    def next_n(count : Int32, from : Time = Time.utc,
               location : Time::Location = Time::Location::UTC) : Array(Time)
      out = [] of Time
      cursor = from
      count.times do
        n = next_after(cursor, location)
        break unless n
        out << n
        cursor = n
      end
      out
    end

    # Human-readable summary of the expression for UI preview.
    def describe : String
      expr = @expr.strip
      if macro_key = MACROS.key_for?(expr) || MACROS.key_for?(MACROS[expr.downcase]? || "")
        return macro_key
      end
      parts = expr.split(/\s+/)
      return expr unless parts.size == 5
      min, hr, dm, mo, dw = parts

      return describe_every(min, "minute") if hr == "*" && dm == "*" && mo == "*" && dw == "*" && step_of(min)
      if dm == "*" && mo == "*" && dw == "*"
        if min == "0" && hr == "*"
          return "every hour"
        elsif min == "0" && hr == "0"
          return "every day at midnight"
        elsif min =~ /^\d+$/ && hr =~ /^\d+$/
          return "every day at #{hr.rjust(2, '0')}:#{min.rjust(2, '0')}"
        elsif hr =~ /^\d+$/ && step_of(min)
          return "every #{step_of(min)} min of hour #{hr}"
        end
      end
      expr
    end

    private def step_of(field : String) : Int32?
      return nil unless field.starts_with?("*/")
      field.sub("*/", "").to_i?
    end

    private def describe_every(field : String, unit : String) : String
      step = step_of(field)
      step ? "every #{step} #{unit}s" : "every #{unit}"
    end

    # Return the next UTC Time strictly greater than `from` whose *wall clock in
    # `location`* matches this expression, or nil if no match within `limit_years`.
    #
    # Timezone semantics match POSIX cron:
    #   - Spring-forward: the skipped local hour simply does not fire.
    #   - Fall-back:      the repeated local hour fires exactly once
    #                     (the first occurrence).
    #
    # Walks cursor_utc minute by minute. Sparse schedules with a mismatched
    # local month jump directly to the next allowed month; everything else
    # walks. Cheap enough because every next_after call resolves within a
    # handful of days.
    def next_after(from : Time, location : Time::Location = Time::Location::UTC,
                   limit_years : Int32 = 5) : Time?
      cursor = (from + 1.minute).at_beginning_of_minute
      deadline = from + limit_years.years

      while cursor < deadline
        local = cursor.in(location)

        unless @month.includes?(local.month)
          cursor = jump_to_next_allowed_month(local, deadline, location)
          next
        end

        if day_matches?(local) && @hour.includes?(local.hour) && @minute.includes?(local.minute)
          # DST fall-back: the same wall clock occurs twice. Fire once.
          prev_local = (cursor - 1.hour).in(location)
          if prev_local.year == local.year && prev_local.month == local.month &&
             prev_local.day == local.day && prev_local.hour == local.hour &&
             prev_local.minute == local.minute
            cursor += 1.minute
            next
          end
          return cursor
        end

        cursor += 1.minute
      end

      nil
    end

    private def jump_to_next_allowed_month(local : Time, deadline : Time,
                                           location : Time::Location) : Time
      year = local.year
      mo = local.month
      loop do
        mo += 1
        if mo > 12
          mo = 1
          year += 1
          break if year > deadline.year
        end
        break if @month.includes?(mo)
      end
      Time.local(year, mo, 1, 0, 0, location: location).to_utc
    end

    private def day_matches?(t : Time) : Bool
      dom_hit = @dom.includes?(t.day)
      dow_hit = @dow.includes?(t.day_of_week.to_i % 7)

      case {@dom_restricted, @dow_restricted}
      when {true, true}  then dom_hit || dow_hit
      when {true, false} then dom_hit
      when {false, true} then dow_hit
      else                    true
      end
    end

    # Expand a single field into a sorted, de-duplicated array of integers.
    private def self.expand(field : String, low : Int32, high : Int32,
                            names : Array(String)? = nil, month_offset : Int32 = 0) : Array(Int32)
      result = Set(Int32).new
      field.split(',').each do |piece|
        result.concat(expand_piece(piece, low, high, names, month_offset))
      end
      raise ParseError.new("field '#{field}' produced no values") if result.empty?
      result.to_a.sort!
    end

    private def self.expand_piece(piece : String, low : Int32, high : Int32,
                                  names : Array(String)?, month_offset : Int32) : Array(Int32)
      range_part, _, step_part = piece.partition('/')
      step = step_part.empty? ? 1 : (step_part.to_i? || raise ParseError.new("bad step '#{step_part}'"))
      raise ParseError.new("step must be positive") unless step > 0

      from, to = if range_part == "*"
                   {low, high}
                 elsif range_part.includes?('-')
                   a, _, b = range_part.partition('-')
                   {parse_value(a, names, month_offset), parse_value(b, names, month_offset)}
                 else
                   v = parse_value(range_part, names, month_offset)
                   step_part.empty? ? {v, v} : {v, high}
                 end

      raise ParseError.new("out-of-range value in '#{piece}'") if from < low || to > high
      raise ParseError.new("inverted range in '#{piece}'") if from > to

      (from..to).step(step).to_a
    end

    private def self.parse_value(raw : String, names : Array(String)?, month_offset : Int32) : Int32
      if v = raw.to_i?
        v
      elsif names && (idx = names.index(raw.upcase))
        idx + month_offset
      else
        raise ParseError.new("bad token '#{raw}'")
      end
    end
  end
end
