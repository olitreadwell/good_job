# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoodJob::Supervisor do
  let(:configuration) { GoodJob::Configuration.new({ subprocesses: 2 }) }
  let(:supervisor) { described_class.new(configuration) }

  describe GoodJob::Supervisor::SubprocessHandle do
    it 'stores the pid, recipe, and restart count' do
      handle = described_class.new(pid: 123, recipe: :recipe, restart_count: 2)

      expect(handle.pid).to eq(123)
      expect(handle.recipe).to eq(:recipe)
      expect(handle.restart_count).to eq(2)
    end

    it 'reports a small, non-negative uptime immediately after being forked' do
      handle = described_class.new(pid: 123, recipe: :recipe)

      expect(handle.uptime).to be >= 0
      expect(handle.uptime).to be < 1
    end
  end

  describe '#backoff_delay' do
    it 'does not delay a first fast replacement' do
      expect(supervisor.send(:backoff_delay, 0)).to eq(0)
      expect(supervisor.send(:backoff_delay, 1)).to eq(0)
    end

    it 'backs off exponentially once a subprocess keeps crashing' do
      expect(supervisor.send(:backoff_delay, 2)).to eq(1)
      expect(supervisor.send(:backoff_delay, 3)).to eq(2)
      expect(supervisor.send(:backoff_delay, 4)).to eq(4)
    end

    it 'caps the delay at MAX_BACKOFF_DELAY' do
      expect(supervisor.send(:backoff_delay, 50)).to eq(GoodJob::Supervisor::MAX_BACKOFF_DELAY)
    end
  end

  describe '#restart_count_after' do
    it 'increments the count for a subprocess that exited before it was healthy' do
      handle = GoodJob::Supervisor::SubprocessHandle.new(pid: 1, recipe: :r, restart_count: 2)
      allow(handle).to receive(:uptime).and_return(GoodJob::Supervisor::MIN_HEALTHY_UPTIME - 1)

      expect(supervisor.send(:restart_count_after, handle)).to eq(3)
    end

    it 'resets the count once a subprocess has run long enough to be healthy' do
      handle = GoodJob::Supervisor::SubprocessHandle.new(pid: 1, recipe: :r, restart_count: 5)
      allow(handle).to receive(:uptime).and_return(GoodJob::Supervisor::MIN_HEALTHY_UPTIME + 1)

      expect(supervisor.send(:restart_count_after, handle)).to eq(0)
    end
  end

  describe '#escalation_timeout' do
    it 'gives a positive drain timeout an extra grace period before SIGKILL' do
      expect(supervisor.send(:escalation_timeout, 10)).to eq(10 + GoodJob::Supervisor::SHUTDOWN_GRACE)
    end

    it 'does not add grace to an immediate (0) shutdown' do
      expect(supervisor.send(:escalation_timeout, 0)).to eq(0)
    end
  end
end
