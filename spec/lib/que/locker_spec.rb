# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Locker do
  subject(:locker) do
    described_class.new(
      queue: queue,
      cursor_expiry: cursor_expiry,
    )
  end

  let(:queue) { "default" }
  let(:cursor_expiry) { 0 }

  describe ".with_locked_job" do
    before { allow(Que).to receive(:execute).and_call_original }

    # Helper to call the with_locked_job method but ensure our block has actually been
    # called. Without this, it's possible that we'd never run expectations in our block.
    def with_locked_job
      block_called = false
      locker.with_locked_job do |job|
        yield(job)
        block_called = true
      end

      raise "did not call job block" unless block_called
    end

    # Simulates actual working of a job, which is useful to these tests to free up another
    # job for locking.
    def expect_to_work(job)
      with_locked_job do |actual_job|
        expect(actual_job[:job_id]).to eql(job[:job_id])
        expect(Que).to receive(:execute).
          with(:unlock_job, [job[:job_id]])

        # Destroy the job to simulate the behaviour of the queue, and allow our lock query
        # to discover new jobs.
        QueJob.find(job[:job_id]).destroy!
      end
    end

    # Our tests are very concerned with which cursor we use and when
    def expect_to_lock_with(cursor:)
      expect(Que).to receive(:execute).with(:lock_job, [queue, cursor])
    end

    context "with no jobs to lock" do
      it "scans entire table and calls block with nil job" do
        expect(Que).to receive(:execute).with(:lock_job, [queue, 0])

        with_locked_job do |job|
          expect(job).to be_nil
        end
      end
    end

    context "with just one job to lock" do
      let!(:job_1) { FakeJob.enqueue(1, queue: queue, priority: 1).attrs }
      let(:cursor_expiry) { 60 }

      # Pretend time isn't moving, as we don't want to test cursor expiry here
      before { allow(Process).to receive(:clock_gettime).and_return(0) }

      # We want our workers to start from the front of the queue immediately after finding
      # no jobs are available to work.
      it "will use a cursor until no jobs are found" do
        expect_to_lock_with(cursor: 0)
        expect_to_work(job_1)

        expect_to_lock_with(cursor: job_1[:job_id])
        with_locked_job {}

        expect_to_lock_with(cursor: 0)
        with_locked_job {}
      end
    end

    context "with jobs to lock" do
      let!(:job_1) { FakeJob.enqueue(1, queue: queue, priority: 1).attrs }
      let!(:job_2) { FakeJob.enqueue(2, queue: queue, priority: 2).attrs }
      let!(:job_3) { FakeJob.enqueue(3, queue: queue, priority: 3).attrs }

      it "locks and then unlocks the most important job" do
        expect_to_lock_with(cursor: 0)
        expect_to_work(job_1)
      end

      # rubocop:disable RSpec/SubjectStub
      # rubocop:disable RSpec/InstanceVariable
      context "on subsequent locks" do
        context "with non-zero cursor expiry" do
          let(:cursor_expiry) { 5 }

          before do
            # we need this to avoid flakiness during resetting the cursor. 
            # Cursors are reset in the beginning when the locker class object is created.
            # It is reset in handle_expired_cursors! method. Sometimes the execution is fast enough that
            # the condition to reset is not met because the Process.clock_gettime remains same(monotonic_now method).
            locker.instance_variable_get(:@queue_expires_at)[queue] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + cursor_expiry
            allow(locker).to receive(:monotonic_now) { @epoch }
          end
          # This test simulates the repeated locking of jobs. We're trying to prove that
          # the locker will use the previous jobs ID as a cursor until the expiry has
          # elapsed, after which we'll reset.
          #
          # We do this by expecting on the calls to lock_job, specifically the second
          # parameter which controls the job_id cursor value.
          it "continues lock from previous job id, until cursor expires" do
            @epoch = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expect_to_lock_with(cursor: 0)
            expect_to_work(job_1)

            @epoch += 2
            expect_to_lock_with(cursor: job_1[:job_id])
            expect_to_work(job_2)

            @epoch += cursor_expiry # our cursor should now expire
            expect_to_lock_with(cursor: 0)
            expect_to_work(job_3)
          end
        end
      end
      # rubocop:enable RSpec/SubjectStub
      # rubocop:enable RSpec/InstanceVariable
    end
  end
end
