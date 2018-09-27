# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Middleware::QueueCollector do
  subject(:collector) { described_class.new(-> (env) { nil }) }

  let(:now) { postgres_now }
  let(:due_now) { now - 1000 }
  let(:pending_now) { now + 1000 }

  before do
    FakeJob.enqueue(run_at: due_now, priority: 1) # due, should be runnable
    FakeJob.enqueue(run_at: due_now, priority: 1) # same as above, for 2nd count
    FakeJob.enqueue(run_at: due_now, priority: 10) # due, different priority
    FakeJob.enqueue(run_at: due_now, priority: 1, retryable: false) # scheduled, not runnable
    FakeJob.enqueue(run_at: pending_now, priority: 1) # not due
    FakeJob.enqueue(run_at: pending_now, queue: "another", priority: 1) # not due, different queue
  end

  describe ".call" do
    it "sets metric values from queue" do
      collector.call({})

      expect(described_class::Queued.values).to eql(
        {queue: "default", job_class: "FakeJob", priority: 1, due: "true"} => 2.0,
        {queue: "default", job_class: "FakeJob", priority: 10, due: "true"} => 1.0,
        {queue: "default", job_class: "FakeJob", priority: 1, due: "false"} => 2.0,
        {queue: "another", job_class: "FakeJob", priority: 1, due: "false"} => 1.0,
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
