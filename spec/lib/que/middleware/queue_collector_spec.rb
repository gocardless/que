# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Middleware::QueueCollector do
  subject(:collector) { described_class.new(->(_env) { nil }) }

  let(:now) { postgres_now }
  let(:due_now) { now - 1000 }
  let(:pending_now) { now + 1000 }

  before do
    FakeJob.enqueue(run_at: due_now, priority: 1) # due, should be runnable
    FakeJob.enqueue(run_at: due_now, priority: 1) # same as above, for 2nd count
    FakeJob.enqueue(run_at: due_now, priority: 10) # due, different priority

    # scheduled, not runnable
    FakeJob.enqueue(run_at: due_now, priority: 1, retryable: false)
    FakeJob.enqueue(run_at: pending_now, priority: 1) # not due

    # Fail a job in the same way it would be failed if the worker had run it
    job_to_fail = FakeJob.enqueue(run_at: due_now, priority: 20, retryable: false)
    error = StandardError.new("bang")
    error.set_backtrace(caller)
    Que::Worker.new.send(:handle_job_failure, error, job_to_fail.attrs)

    # not due, different queue
    FakeJob.enqueue(run_at: pending_now, queue: "another", priority: 1)
  end

  describe ".call" do
    it "sets metric values from queue" do
      collector.call({})

      expect(described_class::Queued.values).to eql(
        { queue: "default", job_class: "FakeJob", priority: "1",
          due: "true", failed:  "false" } => 2.0,
        { queue: "default", job_class: "FakeJob", priority: "10",
          due: "true", failed:  "false" } => 1.0,
        { queue: "default", job_class: "FakeJob", priority: "1",
          due: "false", failed:  "false" } => 2.0,
        { queue: "another", job_class: "FakeJob", priority: "1",
          due: "false", failed:  "false" } => 1.0,
        { queue: "default", job_class: "FakeJob", priority: "20",
          due: "false", failed:  "true" } => 1.0,
      )
    end

    context "when called twice" do
      it "does not include old results that are no longer relevant" do
        # Populate metrics, check we have some counts
        collector.call({})
        QueJob.delete_all

        collector.call({})
        expect(described_class::Queued.values.values.uniq).to eql([0.0])
      end
    end
  end
end
