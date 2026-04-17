module CronLord
  module Runner
    # Executes a Job by spawning a shell process and streaming its output
    # into a LogBuffer. Safe for concurrent use across many jobs.
    #
    # Security notes:
    #   - Command runs under the same UID as the cronlord server. Production
    #     deployments must drop root before `cronlord serve` starts.
    #   - The command string is passed to `/bin/sh -c`, so users define the
    #     shell semantics; arbitrary code execution is by design. Do not
    #     expose the API to untrusted users without a command allowlist.
    class Shell
      def self.run(job : Job, run : Run, buffer : LogBuffer) : Int32
        buffer.write("$ #{job.command}", :meta)

        env = ENV.to_h.merge(job.env)
        chdir = job.working_dir
        if chdir && !Dir.exists?(chdir)
          buffer.write("working_dir does not exist: #{chdir}", :meta)
          return 127
        end

        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe

        process = Process.new(
          command: job.command,
          shell: true,
          env: env,
          clear_env: false,
          chdir: chdir,
          input: Process::Redirect::Close,
          output: stdout_w,
          error: stderr_w,
        )

        # Close parent's write ends so child owns them exclusively.
        stdout_w.close
        stderr_w.close

        done_out = Channel(Nil).new
        done_err = Channel(Nil).new
        spawn pipe_into(stdout_r, buffer, :stdout, done_out)
        spawn pipe_into(stderr_r, buffer, :stderr, done_err)

        timeout = job.timeout_sec
        status : Process::Status? = nil
        timed_out = false

        if timeout > 0
          waiter = Channel(Process::Status).new(1)
          spawn { waiter.send(process.wait) }
          select
          when st = waiter.receive
            status = st
          when timeout(timeout.seconds)
            timed_out = true
            process.signal(Signal::TERM) rescue nil
            sleep 2.seconds
            process.signal(Signal::KILL) rescue nil
            status = waiter.receive
          end
        else
          status = process.wait
        end

        done_out.receive
        done_err.receive

        st = status.not_nil!
        code = st.exit_code
        if timed_out
          buffer.write("[timeout after #{timeout}s, killed]", :meta)
          run.mark_finished("timeout", code, "timeout after #{timeout}s")
        elsif st.success?
          run.mark_finished("success", code)
        else
          run.mark_finished("fail", code)
        end
        code
      ensure
        buffer.close rescue nil
      end

      private def self.pipe_into(io : IO, buffer : LogBuffer, stream : Symbol, done : Channel(Nil))
        while line = io.gets(chomp: true)
          buffer.write(line, stream)
        end
      rescue ex : IO::Error
        buffer.write("[pipe error: #{ex.message}]", :meta)
      ensure
        io.close rescue nil
        done.send(nil)
      end
    end
  end
end
