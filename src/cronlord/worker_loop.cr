require "./worker_client.cr"
require "./worker_runner.cr"

module CronLord
  # The long-running poll loop driving a reference worker. Pulls one run
  # from /api/workers/lease, heartbeats while it executes, then POSTs a
  # terminal result. Blocks on SIGINT/SIGTERM via @stop.
  class WorkerLoop
    @stop = Channel(Nil).new

    def initialize(@client : WorkerClient,
                   @name : String,
                   @lease_sec : Int32 = 60,
                   @poll_sec : Int32 = 5)
    end

    def stop : Nil
      @stop.send(nil) rescue nil
    end

    def run : Nil
      log "worker '#{@name}' polling #{@client.base}"
      loop do
        break if stopped?
        begin
          lease = @client.lease(@lease_sec)
          if lease.nil?
            sleep_or_stop(@poll_sec)
            next
          end
          execute(lease)
        rescue ex : WorkerClient::Error
          log "error: #{ex.message}; backing off #{@poll_sec}s"
          sleep_or_stop(@poll_sec)
        rescue ex
          log "unexpected error: #{ex.class} #{ex.message}; backing off #{@poll_sec}s"
          sleep_or_stop(@poll_sec)
        end
      end
      log "worker '#{@name}' stopped"
    end

    private def execute(lease : WorkerClient::LeaseResponse) : Nil
      run_id = lease.run_id
      job_id = lease.job["id"]?.try(&.as_s?) || "?"
      log "leased run=#{run_id} job=#{job_id}"

      heartbeat_done = Channel(Nil).new
      cancel_chan = Channel(Nil).new(1)
      spawn run_heartbeat(run_id, lease.heartbeat_every, heartbeat_done, cancel_chan)

      result = WorkerRunner.run(lease.job, cancel_chan: cancel_chan)

      heartbeat_done.send(nil) rescue nil

      begin
        @client.finish(run_id, result.status, result.exit_code, result.error, result.log)
        log "finished run=#{run_id} status=#{result.status} exit=#{result.exit_code.inspect}"
      rescue ex : WorkerClient::Error
        # Finish can race with a reaper on a lost lease; log but don't crash
        # the whole worker loop - next lease takes over.
        log "finish failed: #{ex.message}"
      end
    end

    private def run_heartbeat(run_id : String, every : Int32, done : Channel(Nil),
                              cancel_chan : Channel(Nil)) : Nil
      interval = {every, 5}.max
      loop do
        select
        when done.receive
          break
        when timeout(interval.seconds)
          begin
            @client.heartbeat(run_id, @lease_sec)
          rescue WorkerClient::CancelledError
            log "cancel received for run=#{run_id}; signalling runner"
            cancel_chan.send(nil) rescue nil
            break
          rescue ex
            log "heartbeat failed: #{ex.message}"
          end
        end
      end
    end

    private def sleep_or_stop(seconds : Int32) : Nil
      select
      when @stop.receive
        @stop.send(nil) rescue nil # re-signal so main loop sees it
      when timeout(seconds.seconds)
      end
    end

    private def stopped? : Bool
      select
      when @stop.receive
        @stop.send(nil) rescue nil
        true
      else
        false
      end
    end

    private def log(msg : String) : Nil
      STDERR.puts "[worker] #{Time.utc.to_rfc3339} #{msg}"
    end
  end
end
