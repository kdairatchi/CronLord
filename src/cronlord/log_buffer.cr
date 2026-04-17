module CronLord
  # Append-only log file writer that caps on-disk size per run by rotating
  # into a small ring of segments. Each line is also published to any
  # registered subscribers (used by WebSocket tailing).
  class LogBuffer
    getter path : String
    @file : File
    @bytes : Int64 = 0_i64
    @max_bytes : Int64
    @subscribers = Array(Channel(String)).new
    @mutex = Mutex.new
    @closed = false

    def initialize(@path : String, @max_bytes : Int64 = 4_i64 * 1024 * 1024)
      Dir.mkdir_p(File.dirname(@path))
      @file = File.open(@path, "a+")
      @bytes = File.size(@path).to_i64
    end

    def write(line : String, stream : Symbol = :stdout) : Nil
      return if @closed
      stamp = Time.utc.to_rfc3339
      formatted = "#{stamp} #{stream} #{line.chomp}\n"

      @mutex.synchronize do
        if @bytes + formatted.bytesize > @max_bytes
          rotate
        end
        @file.print(formatted)
        @file.flush
        @bytes += formatted.bytesize
      end

      @subscribers.each do |ch|
        select
        when ch.send(formatted)
          # delivered
        else
          # slow consumer — drop; prevents scheduler stalls
        end
      end
    end

    def subscribe : Channel(String)
      ch = Channel(String).new(256)
      @mutex.synchronize { @subscribers << ch }
      ch
    end

    def unsubscribe(ch : Channel(String))
      @mutex.synchronize { @subscribers.delete(ch) }
      ch.close
    end

    def close
      @mutex.synchronize do
        return if @closed
        @closed = true
        @file.close
        @subscribers.each(&.close)
        @subscribers.clear
      end
    end

    private def rotate
      @file.close
      rotated = "#{@path}.1"
      File.delete(rotated) if File.exists?(rotated)
      File.rename(@path, rotated)
      @file = File.open(@path, "a+")
      @bytes = 0_i64
    end
  end
end
