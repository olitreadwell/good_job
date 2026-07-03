# frozen_string_literal: true

module GoodJob # :nodoc:
  #
  # A Supervisor runs GoodJob in "cluster mode": instead of executing jobs in
  # the current process, it forks and supervises +GOOD_JOB_SUBPROCESSES+ child
  # processes, each of which runs its own {GoodJob::Capsule} via
  # {GoodJob::Subprocess}. Forking lets the operating system share loaded
  # Rails/application memory pages copy-on-write across the subprocesses.
  #
  # The Supervisor itself runs no Capsule, Scheduler, or Notifier — it only
  # forks, monitors, and (when a subprocess dies unexpectedly) replaces its
  # children, and coordinates graceful shutdown. Forking is only ever performed
  # from the main thread (inside {#start}) to avoid a forked child inheriting a
  # mutex left locked by another thread.
  #
  class Supervisor
    # Seconds the supervise loop sleeps between polling for exited subprocesses.
    # +SIGCHLD+ interrupts this sleep so replacement is prompt; the interval is
    # only a backstop.
    SUPERVISE_INTERVAL = 5

    # Seconds between polls while waiting for subprocesses to exit during a
    # bounded (timeout) shutdown.
    REAP_INTERVAL = 0.1

    # Extra seconds the supervisor waits after +SIGTERM+ — on top of a
    # subprocess's own drain budget (its +shutdown_timeout+) — before escalating
    # to +SIGKILL+, so a subprocess still draining within its budget is not
    # killed prematurely.
    SHUTDOWN_GRACE = 5

    # Signals that trigger a graceful shutdown (drain jobs, then exit).
    GRACEFUL_SIGNALS = %w[INT TERM].freeze
    # Signals that trigger an immediate shutdown (interrupt running jobs).
    IMMEDIATE_SIGNALS = %w[QUIT].freeze

    # A subprocess that exits sooner than this many seconds after being forked
    # is treated as a failed boot; its replacement is delayed with backoff.
    MIN_HEALTHY_UPTIME = 10

    # Bounds (seconds) for the exponential backoff between replacements of a
    # repeatedly crash-looping subprocess.
    MIN_BACKOFF_DELAY = 1
    MAX_BACKOFF_DELAY = 30

    # Monotonic time in seconds, used for internal timeouts so a wall-clock
    # change can't skew them.
    # @return [Float]
    def self.monotonic
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    # The supervisor's record of a single forked subprocess: enough to monitor
    # its lifetime and re-fork a replacement from the same recipe (with backoff
    # when it is crash-looping). +recipe+ is the {GoodJob::Configuration} the
    # subprocess runs; +restart_count+ is the number of consecutive fast exits
    # that led to this subprocess being forked.
    class SubprocessHandle
      attr_reader :pid, :recipe, :restart_count

      def initialize(pid:, recipe:, restart_count: 0)
        @pid = pid
        @recipe = recipe
        @restart_count = restart_count
        @started_at = Supervisor.monotonic
      end

      # Seconds since this subprocess was forked (monotonic, immune to wall-clock changes).
      # @return [Float]
      def uptime
        Supervisor.monotonic - @started_at
      end
    end

    # @param configuration [GoodJob::Configuration] Configuration shared by every subprocess.
    def initialize(configuration = GoodJob.configuration)
      @configuration = configuration
      @subprocesses = {} # pid => SubprocessHandle; only mutated from the main thread
      @received_signals = []
      @self_pipe_reader, @self_pipe_writer = IO.pipe
      @stopped = false
      @shutdown_timeout = nil
    end

    # Forks the configured number of subprocesses and blocks, supervising them,
    # until a shutdown signal (+SIGINT+/+SIGTERM+ for graceful, +SIGQUIT+ for
    # immediate) is received. When it returns, all subprocesses have exited.
    # @return [void]
    def start
      @supervisor_pid = ::Process.pid
      install_signal_handlers

      ActiveSupport::Notifications.instrument("cluster_start.good_job", { subprocesses: @configuration.subprocesses })
      @configuration.subprocesses.times { spawn_subprocess }

      supervise
    ensure
      restore_signal_handlers
      @self_pipe_reader.close unless @self_pipe_reader.closed?
      @self_pipe_writer.close unless @self_pipe_writer.closed?
    end

    # @return [Boolean] Whether the supervisor is currently supervising subprocesses.
    def running?
      !@stopped && @supervisor_pid == ::Process.pid
    end

    private

    # The main supervise loop. Runs on the calling (main) thread so that all
    # forking happens on the main thread.
    # @return [void]
    def supervise
      until @stopped
        process_signals
        break if @stopped

        reap_and_replace
        wait_for_wakeup
      end

      terminate_subprocesses(@shutdown_timeout.nil? ? @configuration.shutdown_timeout : @shutdown_timeout)
      ActiveSupport::Notifications.instrument("cluster_shutdown.good_job", { pid: @supervisor_pid })
    end

    # Forks a single subprocess running the given recipe (its {GoodJob::Configuration})
    # and records a {SubprocessHandle} for it. Must only be called from the main thread.
    # @param recipe [GoodJob::Configuration]
    # @param restart_count [Integer] Consecutive fast-exit count carried to the new subprocess.
    # @return [Integer] The forked process's PID.
    def spawn_subprocess(recipe = @configuration, restart_count: 0)
      supervisor_pid = @supervisor_pid
      pid = fork do
        GoodJob::Subprocess.new(configuration: recipe, supervisor_pid: supervisor_pid).run
      rescue StandardError => e
        GoodJob._on_thread_error(e)
        exit!(1)
      end

      @subprocesses[pid] = SubprocessHandle.new(pid: pid, recipe: recipe, restart_count: restart_count)
      ActiveSupport::Notifications.instrument("cluster_spawn.good_job", { pid: pid })
      pid
    end

    # Reaps any subprocesses that have exited and, unless the supervisor is
    # shutting down, forks a replacement for each from its original recipe. A
    # subprocess that exited too quickly to be considered healthy is replaced
    # with exponential backoff to avoid a hot crash-restart loop.
    # @return [void]
    def reap_and_replace
      loop do
        pid, status = ::Process.wait2(-1, ::Process::WNOHANG)
        break unless pid

        handle = @subprocesses.delete(pid)
        ActiveSupport::Notifications.instrument("cluster_reap.good_job", { pid: pid, status: status&.exitstatus })
        next if @stopped || handle.nil?

        restart_count = restart_count_after(handle)
        backoff(restart_count)
        break if @stopped # a shutdown signal arrived during the backoff

        spawn_subprocess(handle.recipe, restart_count: restart_count)
      end
    rescue Errno::ECHILD
      # No child processes exist yet or any longer.
    end

    # The consecutive-fast-exit count to assign a subprocess's replacement: it
    # grows while a subprocess keeps exiting before {MIN_HEALTHY_UPTIME}, and
    # resets once a subprocess has run long enough to be considered healthy.
    # @param handle [SubprocessHandle]
    # @return [Integer]
    def restart_count_after(handle)
      handle.uptime < MIN_HEALTHY_UPTIME ? handle.restart_count + 1 : 0
    end

    # Waits (interruptibly) for the backoff delay appropriate to +restart_count+
    # before replacing a crash-looping subprocess. A shutdown signal cuts the
    # wait short and sets @stopped via {#process_signals}.
    # @param restart_count [Integer]
    # @return [void]
    def backoff(restart_count)
      delay = backoff_delay(restart_count)
      return if delay.zero?

      ActiveSupport::Notifications.instrument("cluster_backoff.good_job", { restart_count: restart_count, delay: delay })
      drain_self_pipe # discard stale wakeups so the delay is real
      IO.select([@self_pipe_reader], nil, nil, delay)
      process_signals
    end

    # Exponential backoff (seconds) between replacements of a crash-looping
    # subprocess: 0 for a first fast exit, then MIN_BACKOFF_DELAY doubling up to
    # MAX_BACKOFF_DELAY.
    # @param restart_count [Integer]
    # @return [Integer]
    def backoff_delay(restart_count)
      return 0 if restart_count < 2

      [MIN_BACKOFF_DELAY * (2**(restart_count - 2)), MAX_BACKOFF_DELAY].min
    end

    # Signals all subprocesses to shut down and waits for them to exit,
    # escalating to +SIGKILL+ if a positive +timeout+ elapses.
    # @param timeout [nil, Numeric] +nil+ triggers but does not wait; a negative
    #   value waits forever; +0+ or a positive value waits that many seconds
    #   before killing survivors.
    # @return [void]
    def terminate_subprocesses(timeout)
      signal_subprocesses("TERM")

      if timeout.nil?
        nil
      elsif timeout.negative?
        reap_all_blocking
      elsif !reap_all_until(Supervisor.monotonic + escalation_timeout(timeout))
        signal_subprocesses("KILL")
        reap_all_blocking
      end
    end

    # Seconds to wait after +SIGTERM+ before escalating to +SIGKILL+. Each
    # subprocess drains for +timeout+, so the supervisor waits that long plus
    # {SHUTDOWN_GRACE} for it to actually exit; it never kills a subprocess that
    # is still within its own drain budget. Immediate shutdown (+0+) gets no grace.
    # @param timeout [Numeric] a non-negative drain timeout
    # @return [Numeric]
    def escalation_timeout(timeout)
      timeout.positive? ? timeout + SHUTDOWN_GRACE : timeout
    end

    # @param signal [String]
    # @return [void]
    def signal_subprocesses(signal)
      @subprocesses.each_key do |pid|
        ::Process.kill(signal, pid)
      rescue Errno::ESRCH
        # Already gone; it will be reaped.
      end
    end

    # Blocks until every recorded subprocess has been reaped.
    # @return [void]
    def reap_all_blocking
      until @subprocesses.empty?
        begin
          pid, _status = ::Process.wait2
        rescue Errno::ECHILD
          break
        end
        @subprocesses.delete(pid)
      end
    end

    # Polls (non-blocking) until every subprocess is reaped or the deadline passes.
    # @param deadline [Time]
    # @return [Boolean] Whether all subprocesses exited before the deadline.
    def reap_all_until(deadline)
      loop do
        return true if @subprocesses.empty?

        begin
          pid, _status = ::Process.wait2(-1, ::Process::WNOHANG)
        rescue Errno::ECHILD
          return true
        end

        if pid
          @subprocesses.delete(pid)
        elsif Supervisor.monotonic >= deadline
          return false
        else
          sleep REAP_INTERVAL
        end
      end
    end

    # Drains signals received since the last iteration, updating shutdown state.
    # Ruby runs +trap+ blocks at VM safe points, so mutating state here is safe.
    # @return [void]
    def process_signals
      until @received_signals.empty?
        signal = @received_signals.shift
        if GRACEFUL_SIGNALS.include?(signal)
          @stopped = true
          @shutdown_timeout ||= @configuration.shutdown_timeout
        elsif IMMEDIATE_SIGNALS.include?(signal)
          @stopped = true
          @shutdown_timeout = 0
        end
      end
    end

    # @return [void]
    def install_signal_handlers
      (GRACEFUL_SIGNALS + IMMEDIATE_SIGNALS).each do |signal|
        trap(signal) do
          @received_signals << signal
          wake
        end
      end
      # Wake promptly to reap (and replace) a subprocess as soon as it exits.
      trap("CHLD") { wake }
    end

    # Wakes the supervise loop by writing to the self-pipe. Safe to call from a
    # +trap+ handler: a bare +IO#write_nonblock+ acquires no Ruby mutex, unlike
    # +Concurrent::Event#set+ (which raises "can't be called from trap context").
    # @return [void]
    def wake
      @self_pipe_writer.write_nonblock(".", exception: false)
    rescue IOError
      nil
    end

    # Blocks until the self-pipe becomes readable (a signal arrived) or the poll
    # interval elapses, then drains anything buffered in the pipe.
    # @return [void]
    def wait_for_wakeup
      IO.select([@self_pipe_reader], nil, nil, SUPERVISE_INTERVAL)
      drain_self_pipe
    end

    # Discards any bytes buffered in the self-pipe by signal handlers.
    # @return [void]
    def drain_self_pipe
      # read_nonblock raises IO::WaitReadable once the pipe is drained; IOError
      # (a superclass of EOFError) covers a closed pipe during shutdown.
      loop { @self_pipe_reader.read_nonblock(256) }
    rescue IO::WaitReadable, IOError
      nil
    end

    # @return [void]
    def restore_signal_handlers
      (GRACEFUL_SIGNALS + IMMEDIATE_SIGNALS + %w[CHLD]).each do |signal|
        trap(signal, "DEFAULT")
      rescue ArgumentError
        # Signal not supported on this platform.
      end
    end
  end
end
