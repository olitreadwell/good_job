# frozen_string_literal: true

require 'concurrent/atomic/event'

module GoodJob # :nodoc:
  #
  # Runs a single {GoodJob::Capsule} inside a subprocess forked by a
  # {GoodJob::Supervisor}. A Subprocess is only used in cluster mode
  # (+GOOD_JOB_SUBPROCESSES+ >= 1). It is instantiated in the child process
  # immediately after +fork+ and is responsible for re-establishing resources
  # that cannot be safely inherited across a fork (database connections,
  # background threads) before booting its Capsule.
  #
  class Subprocess
    # Seconds the subprocess waits between checking whether it should shut down.
    # This also bounds how quickly an orphaned subprocess (whose supervisor has
    # died) notices and exits.
    CHECK_INTERVAL = 5

    # @param configuration [GoodJob::Configuration] Configuration for this subprocess's Capsule.
    # @param supervisor_pid [Integer] PID of the supervisor process; used to detect orphaning.
    def initialize(configuration:, supervisor_pid: ::Process.ppid)
      @configuration = configuration
      @supervisor_pid = supervisor_pid
      @stop_subprocess = Concurrent::Event.new
    end

    # Boots the Capsule and blocks until the subprocess is told to shut down (via
    # +SIGTERM+/+SIGINT+), its Capsule shuts itself down, or it is orphaned by a
    # dead supervisor. Intended to be the last thing that runs in a forked child;
    # the process should exit once this method returns.
    # @return [void]
    def run
      GoodJob.run_lifecycle_hooks(:before_subprocess_boot)

      @capsule = GoodJob::Capsule.new(configuration: @configuration)
      @capsule.start

      install_signal_handlers
      ActiveSupport::Notifications.instrument("subprocess_start.good_job", { pid: ::Process.pid })

      Kernel.loop do
        @stop_subprocess.wait(CHECK_INTERVAL)
        break if @stop_subprocess.set? || @capsule.shutdown? || orphaned?
      end

      # Emit the shutdown notification *before* draining, so it is recorded even
      # if a slow drain is cut short by a SIGKILL (the supervisor's TERM->KILL
      # escalation on a finite shutdown_timeout, systemd/Kubernetes stop
      # timeouts, or `kill -9`) — nothing can be emitted after a SIGKILL. The
      # wrapping event still records the drain's duration on a clean shutdown.
      ActiveSupport::Notifications.instrument("subprocess_shutdown_start.good_job", { pid: ::Process.pid })
      ActiveSupport::Notifications.instrument("subprocess_shutdown.good_job", { pid: ::Process.pid }) do
        @capsule.shutdown(timeout: @configuration.shutdown_timeout)
      end
    end

    private

    # @return [void]
    def install_signal_handlers
      %w[INT TERM].each do |signal|
        trap(signal) { Thread.new { @stop_subprocess.set }.join }
      end
    end

    # @return [Boolean] Whether the supervisor that forked this subprocess is gone.
    def orphaned?
      ::Process.ppid != @supervisor_pid
    end
  end
end
