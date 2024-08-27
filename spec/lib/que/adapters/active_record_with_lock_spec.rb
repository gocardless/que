# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Adapters::ActiveRecordWithLock, :active_record_with_lock do
  subject(:adapter) do
    described_class.new(job_connection_pool: JobRecord.connection_pool,
                        lock_connection_pool: LockDatabaseRecord.connection_pool)
  end

  before do
    described_class::FindJobHitTotal.values.each { |labels, _| labels.clear }
  end

  context "with enqueued jobs" do
    before do
      10.times do
        FakeJob.enqueue(1)
      end
    end

    it "sets correct metric values" do
      expect(QueJob.count).to eq(10)
      with_workers(5) { wait_for_jobs_to_be_worked }
      expect(QueJob.count).to eq(0)
      expect(described_class::FindJobHitTotal.values[{ :queue => "default", :job_hit => "true" }]).to eq(10.0)
    end
  end

  describe ".lock_job_with_lock_database" do
    subject(:lock_job) { adapter.lock_job_with_lock_database("default", 0) }

    context "with no jobs enqueued" do
      it "exists the loop and sets correct metric values" do
        expect(QueJob.count).to eq(0)
        locked_job = lock_job
        expect(locked_job).to eq([])
        expect(described_class::FindJobHitTotal.values[{ :queue => "default", :job_hit => "true" }]).to eq(0.0)
      end
    end
  end
end
