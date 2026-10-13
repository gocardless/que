# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Middleware::QueueCollector do
  subject(:collector) { described_class.new(->(_env) {}, options) }

  let(:options) { { refresh_interval: 0 } }
  let(:now) { postgres_now }
  let(:due_now_delay) { 1000.0 }
  let(:due_later_than_now_delay) { due_now_delay / 2 }
  let(:due_now) { now - due_now_delay }
  let(:due_later_than_now) { now - due_later_than_now_delay }
  let(:pending_now) { now + 1000 }

  before do
    # Gauges are process-global, so give each example fresh series. Otherwise label sets
    # from other examples (e.g. ActiveJob classes) leak into the exact matches below.
    [described_class::Queued, described_class::QueuedPastDue].each do |gauge|
      gauge.send(
        :replace_internal_store,
        Prometheus::Client.config.data_store.for_metric(gauge.name, metric_type: gauge.type),
      )
    end

    FakeJob.enqueue(run_at: due_now, priority: 1) # due, should be runnable
    FakeJob.enqueue(run_at: due_later_than_now, priority: 1) # same as above, for 2nd count
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

    it "sets past due metric values from queue" do
      collector.call({})

      expect(described_class::QueuedPastDue.values).to eql(
        { queue: "default", job_class: "FakeJob", priority: "1",
          due: "true", failed:  "false" } => due_now_delay,
        { queue: "default", job_class: "FakeJob", priority: "10",
          due: "true", failed:  "false" } => due_now_delay,
        { queue: "default", job_class: "FakeJob", priority: "1",
          due: "false", failed:  "false" } => 0.0,
        { queue: "another", job_class: "FakeJob", priority: "1",
          due: "false", failed:  "false" } => 0.0,
        { queue: "default", job_class: "FakeJob", priority: "20",
          due: "false", failed:  "true" } => 0.0,
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

    context "when creating a collector" do
      let(:registry) { instance_double(Prometheus::Client::Registry) }
      let(:options) do
        {
          registry: registry,
        }
      end

      it "will register metrics" do
        expect(registry).to receive(:register).with(described_class::Queued)
        expect(registry).to receive(:register).with(described_class::QueuedPastDue)
        expect(registry).to receive(:register).with(described_class::RefreshDuration)
        expect(registry).to receive(:register).with(described_class::RefreshErrorsTotal)

        collector
      end
    end
  end

  describe "ActiveJob wrapped jobs" do
    let(:wrapper) { "ActiveJob::QueueAdapters::QueAdapter::JobWrapper" }

    before do
      Que.execute(:insert_job, ["default", 1, due_now, wrapper, true, [{ "job_class" => "MyActiveJob" }]])
    end

    it "reports the wrapped class instead of the wrapper" do
      collector.call({})

      expect(described_class::Queued.values).to include(
        { queue: "default", job_class: "MyActiveJob", priority: "1",
          due: "true", failed: "false" } => 1.0,
      )
      expect(described_class::Queued.values.keys.map { |labels| labels[:job_class] }).
        to_not include(wrapper)
    end

    it "leaves native job classes unchanged" do
      collector.call({})

      expect(described_class::Queued.values).to include(
        { queue: "default", job_class: "FakeJob", priority: "1",
          due: "true", failed: "false" } => 2.0,
      )
    end
  end

  describe "refresh metrics" do
    it "records the refresh duration" do
      collector.call({})

      expect(described_class::RefreshDuration.values.fetch({})).to be > 0
    end

    it "counts failed refreshes" do
      allow(Que).to receive(:execute).and_call_original
      allow(Que).to receive(:execute).
        with("refresh materialized view que_jobs_summary;").
        and_raise(PG::QueryCanceled, "canceling statement due to statement timeout")

      expect { collector.call({}) }.
        to change { described_class::RefreshErrorsTotal.values.fetch({}, 0.0) }.by(1.0)
    end
  end
end
