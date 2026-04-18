module CronLord
  module Runner
    # Process-local registry of in-flight cancellable runs. Runners register
    # a channel when they start executing; the API's cancel endpoint signals
    # that channel when a cancel request lands on the same scheduler host.
    #
    # Only local (on-host) runs are reachable this way. Worker-leased runs
    # learn about cancellation through a 410 response on their next
    # heartbeat - that path does not touch this registry.
    module CancelRegistry
      extend self

      @@entries = Hash(String, Channel(Nil)).new
      @@mutex = Mutex.new

      # Register a cancel channel for `run_id`. Callers should `ensure`
      # unregister so the hash doesn't leak if the runner raises.
      def register(run_id : String) : Channel(Nil)
        chan = Channel(Nil).new(1)
        @@mutex.synchronize { @@entries[run_id] = chan }
        chan
      end

      # Remove `run_id` from the registry. Idempotent.
      def unregister(run_id : String) : Nil
        @@mutex.synchronize { @@entries.delete(run_id) }
      end

      # Fire the cancel channel for `run_id`. Returns true if a runner was
      # registered, false otherwise (run is either remote, already finished,
      # or never started on this host).
      def signal(run_id : String) : Bool
        chan = @@mutex.synchronize { @@entries[run_id]? }
        return false unless chan
        # Buffered channel capacity = 1; send never blocks for the first
        # cancel. Drop duplicate cancels silently.
        chan.send(nil) rescue nil
        true
      end

      # Test helper - current size of the registry.
      def size : Int32
        @@mutex.synchronize { @@entries.size }
      end
    end
  end
end
