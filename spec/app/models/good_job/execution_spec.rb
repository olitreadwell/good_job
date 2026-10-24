# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoodJob::Execution do
  let(:active_job_id) { SecureRandom.uuid }

  let(:job) do
    GoodJob::Job.create!(
      id: active_job_id,
      active_job_id: active_job_id,
      queue_name: 'mice',
      job_class: 'TestJob',
      serialized_params: { 'job_class' => 'TestJob' }
    )
  end

  let(:execution) do
    job.executions.create!(
      queue_name: 'mice',
      scheduled_at: 10.minutes.ago,
      created_at: 5.minutes.ago,
      serialized_params: { 'job_class' => 'TestJob', 'executions' => 1 }
    )
  end

  describe '#number' do
    it 'is the executions count from the serialized params plus one' do
      expect(execution.number).to eq 2
    end

    it 'defaults to one when the serialized params lack an executions count' do
      execution.update!(serialized_params: { 'job_class' => 'TestJob' })

      expect(execution.number).to eq 1
    end
  end

  describe '#queue_latency' do
    it 'is the time between when the job was scheduled and when it started' do
      expect(execution.queue_latency).to be_within(1.second).of(5.minutes)
    end
  end

  describe '#runtime_latency' do
    it 'returns the stored duration' do
      execution.update!(duration: 45.seconds)

      expect(execution.runtime_latency).to eq 45.seconds
    end
  end

  describe '#last_status_at' do
    it 'is finished_at when the execution has finished' do
      execution.update!(finished_at: 1.minute.ago)
      execution.reload

      expect(execution.last_status_at).to eq execution.finished_at
    end

    it 'is created_at when the execution is still running' do
      expect(execution.last_status_at).to eq execution.created_at
    end
  end

  describe '#status' do
    it 'is :running while the execution is in progress' do
      expect(execution.status).to eq :running
    end

    it 'is :succeeded when the execution finished without an error' do
      execution.update!(finished_at: Time.current)

      expect(execution.status).to eq :succeeded
    end

    it 'is :retried when the execution finished with an error but the job was not discarded' do
      execution.update!(finished_at: Time.current, error: 'TestJob::Error: boom')

      expect(execution.status).to eq :retried
    end

    it 'is :discarded when the execution finished with an error and the job was discarded' do
      job.update!(finished_at: Time.current, error: 'TestJob::Error: boom')
      execution.update!(finished_at: Time.current, error: 'TestJob::Error: boom')

      expect(execution.status).to eq :discarded
    end
  end

  describe '#interrupted_duration' do
    it 'is the time between when the execution started and finished for an interrupted run' do
      execution.update!(
        created_at: 5.minutes.ago,
        finished_at: 1.minute.ago,
        error_event: :interrupted
      )

      expect(execution.interrupted_duration).to be_within(1.second).of(4.minutes)
    end

    it 'is nil when the error event is not interrupted' do
      execution.update!(finished_at: 1.minute.ago, error_event: :unhandled)

      expect(execution.interrupted_duration).to be_nil
    end

    it 'is nil when the execution has not finished' do
      execution.update!(error_event: :interrupted)

      expect(execution.interrupted_duration).to be_nil
    end
  end

  describe '#display_serialized_params' do
    it 'includes the serialized params' do
      expect(execution.display_serialized_params).to include('job_class' => 'TestJob', 'executions' => 1)
    end

    it 'merges in the execution attributes under _good_job_execution' do
      result = execution.display_serialized_params

      expect(result[:_good_job_execution]).to include('id' => execution.id, 'active_job_id' => active_job_id)
    end

    it 'omits the raw serialized_params from the execution attributes' do
      expect(execution.display_serialized_params[:_good_job_execution]).not_to have_key('serialized_params')
    end
  end

  describe '#filtered_error_backtrace' do
    it 'cleans the backtrace with the Rails backtrace cleaner' do
      app_frame = Rails.root.join("app/models/demo_job.rb:5:in `perform`").to_s
      gem_frame = "/usr/local/lib/ruby/gems/3.0.0/gems/foo/lib/foo.rb:2:in `bar`"

      execution.update!(error_backtrace: [app_frame, gem_frame])

      expect(execution.filtered_error_backtrace).to eq ["app/models/demo_job.rb:5:in `perform`"]
    end

    it 'is empty when there is no backtrace' do
      expect(execution.filtered_error_backtrace).to eq []
    end
  end
end
