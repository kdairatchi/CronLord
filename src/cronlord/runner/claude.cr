module CronLord
  module Runner
    # Runs the Claude CLI non-interactively with the job command as the prompt.
    # This keeps CronLord agnostic to API keys - the CLI handles auth via its
    # normal env (`ANTHROPIC_API_KEY`) and settings.
    #
    # The job command is fed to `claude -p <prompt>`. stdout + stderr are
    # streamed into the run log via the same pipe-into pattern as Shell.
    class Claude
      DEFAULT_CLI = "claude"

      def self.run(job : Job, run : Run, buffer : LogBuffer) : Int32
        cli = job.env["CLAUDE_CLI"]? || ENV["CRONLORD_CLAUDE_CLI"]? || DEFAULT_CLI
        prompt = job.command
        args = ["-p", prompt]
        if model = job.args["model"]?.try(&.as_s?)
          args << "--model" << model
        end

        buffer.write("$ #{cli} -p <prompt> (#{prompt.size} chars)", :meta)

        env = ENV.to_h.merge(job.env)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe

        process = Process.new(
          command: cli,
          args: args,
          env: env,
          clear_env: false,
          chdir: job.working_dir,
          input: Process::Redirect::Close,
          output: stdout_w,
          error: stderr_w,
        )
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
      rescue ex : File::NotFoundError
        buffer.write("[claude cli not found: '#{ex.message}' - install Claude Code CLI]", :meta) rescue nil
        run.mark_finished("fail", 127, ex.message)
        127
      ensure
        buffer.close rescue nil
      end

      private def self.pipe_into(io : IO, buffer : LogBuffer, stream : Symbol, done : Channel(Nil))
        while line = io.gets(chomp: true)
          buffer.write(line, stream)
        end
      rescue ex : IO::Error
        buffer.write("[pipe error: #{ex.message}]", :meta) rescue nil
      ensure
        io.close rescue nil
        done.send(nil)
      end
    end
  end
end
