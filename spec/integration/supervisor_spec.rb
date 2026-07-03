# frozen_string_literal: true

require 'rails_helper'

# Boots a real supervisor and its subprocesses via the +good_job+ executable
# and asserts on the structured log output. Following Puma's integration-test
# approach, every wait polls with a deadline (via +wait_until+) rather than
# sleeping for a fixed time, which keeps the specs deterministic.
RSpec.describe 'Cluster mode', :skip_if_java do
  let(:env) do
    {
      "RAILS_ENV" => "test",
      "GOOD_JOB_SUBPROCESSES" => "2",
      "GOOD_JOB_MAX_THREADS" => "1",
      "GOOD_JOB_POLL_INTERVAL" => "30",
      "GOOD_JOB_SHUTDOWN_TIMEOUT" => "5",
      # macOS forbids calling into some system libraries (e.g. libpq) after
      # fork(); this env var relaxes that. It is a no-op on Linux (CI), but lets
      # the suite run on a developer's Mac.
      "OBJC_DISABLE_INITIALIZE_FORK_SAFETY" => "YES",
    }
  end

  # @return [Array<Integer>] the OS PIDs of subprocesses that have booted, parsed from the log.
  def booted_subprocess_pids(output)
    output.join.scan(/started subprocess \(PID: (\d+)\)/).flatten.map(&:to_i).uniq
  end

  # @return [Integer] the PID of a subprocess's parent, i.e. the supervisor.
  def supervisor_pid_for(subprocess_pid)
    `ps -o ppid= -p #{subprocess_pid}`.strip.to_i
  end

  it 'forks and boots the configured number of subprocesses' do
    ShellOut.command("bundle exec good_job start", env: env) do |shell|
      wait_until(max: 30, increments_of: 0.5) do
        expect(shell.output).to include(/started supervisor with subprocesses=2/)
        expect(booted_subprocess_pids(shell.output).size).to eq(2)
      end
    end
  end

  it 'replaces a subprocess that exits unexpectedly' do
    ShellOut.command("bundle exec good_job start", env: env) do |shell|
      original_pids = nil
      wait_until(max: 30, increments_of: 0.5) do
        original_pids = booted_subprocess_pids(shell.output)
        expect(original_pids.size).to eq(2)
      end

      Process.kill("TERM", original_pids.first)

      wait_until(max: 30, increments_of: 0.5) do
        # A subprocess with a PID not in the original set has since booted.
        expect(booted_subprocess_pids(shell.output) - original_pids).not_to be_empty
      end
    end
  end

  it 'gracefully shuts its subprocesses down when it is terminated' do
    ShellOut.command("bundle exec good_job start", env: env) do |shell|
      pids = nil
      wait_until(max: 30, increments_of: 0.5) do
        pids = booted_subprocess_pids(shell.output)
        expect(pids.size).to eq(2)
      end

      Process.kill("TERM", supervisor_pid_for(pids.first))

      wait_until(max: 30, increments_of: 0.5) do
        expect(shell.output).to include(/shutting down subprocess/)
        expect(shell.output).to include(/shutting down scheduler/)
        expect(shell.output).to include(/supervisor is shut down/)
      end
    end
  end
end
