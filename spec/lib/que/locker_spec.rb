# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Locker do
  subject(:locker) do
    described_class.new(
      queue: queue,
      cursor_expiry: cursor_expiry,
      job_buffer: job_buffer,
    )
  end

  let(:queue) { "default" }
  let(:cursor_expiry) { 0 }
  let(:job_buffer) { Que::JobBuffer.new(maximum_size: buffer_size) }
  let(:buffer_size) { 10 }

  # Avoid leaking held advisory locks across examples for jobs left buffered but never
  # worked by a test.
  after do
    job_buffer.clear.each { |job| Que.execute(:unlock_job, [job[:job_id]]) }
  end

  describe "#poll (via #start)" do
    before { allow(Que).to receive(:execute).and_call_original }

    # Runs a single poll cycle directly (rather than starting the background thread),
    # so we can assert deterministically on what got locked and pushed.
    def poll
      locker.send(:poll)
    end

    # Simulates a worker successfully finishing the job, so its slot in the buffer frees
    # up and its advisory lock is released, exactly as Worker#unlock would (including
    # releasing it from the buffer's held-ids set).
    def work(job)
      job_hash = job_buffer.shift
      expect(job_hash[:job_id]).to eql(job[:job_id])
      Que.execute(:unlock_job, [job_hash[:job_id]])
      job_buffer.release(job_hash[:job_id])

      # Destroy the job to simulate the behaviour of the queue, and allow our lock query
      # to discover new jobs.
      QueJob.find(job[:job_id]).destroy!
    end

    # held_ids is computed from the buffer's actual current state, since it changes as
    # jobs are locked/pushed/worked over the course of a test.
    def expect_to_lock_with(cursor:, run_at_lower_bound: nil, limit: buffer_size)
      held_ids = "{#{job_buffer.held_ids.join(',')}}"
      expect(Que).to receive(:execute).
        with(:lock_jobs_batch, [queue, cursor, run_at_lower_bound, limit, held_ids])
    end

    context "with no jobs to lock" do
      it "scans entire table and leaves the buffer empty" do
        expect(Que).to receive(:execute).with(:lock_jobs_batch, [queue, 0, nil, buffer_size, "{}"])

        poll

        expect(job_buffer.size).to eq(0)
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
        poll
        work(job_1)

        expect_to_lock_with(cursor: job_1[:job_id])
        poll

        expect_to_lock_with(cursor: 0)
        poll
      end
    end

    context "with jobs to lock" do
      let!(:job_1) { FakeJob.enqueue(1, queue: queue, priority: 1).attrs }
      let!(:job_2) { FakeJob.enqueue(2, queue: queue, priority: 2).attrs }
      let!(:job_3) { FakeJob.enqueue(3, queue: queue, priority: 3).attrs }

      it "locks all due jobs (up to the buffer's capacity) in a single poll" do
        expect_to_lock_with(cursor: 0)
        poll

        expect(job_buffer.size).to eq(3)
      end

      context "when the buffer has less capacity than there are jobs" do
        let(:buffer_size) { 2 }

        it "locks only as many jobs as fit" do
          expect_to_lock_with(cursor: 0, limit: 2)
          poll

          expect(job_buffer.size).to eq(2)
        end
      end

      # rubocop:disable RSpec/SubjectStub
      # rubocop:disable RSpec/InstanceVariable
      context "on subsequent polls" do
        context "with non-zero cursor expiry" do
          let(:cursor_expiry) { 5 }
          let(:buffer_size) { 1 }

          before do
            # we need this to avoid flakiness during resetting the cursor.
            # Cursors are reset in the beginning when the locker class object is created.
            # It is reset in handle_expired_cursors! method. Sometimes the execution is fast enough that
            # the condition to reset is not met because the Process.clock_gettime remains same(monotonic_now method).
            locker.instance_variable_get(:@queue_expires_at)[queue] =
              Process.clock_gettime(Process::CLOCK_MONOTONIC) + cursor_expiry
            allow(locker).to receive(:monotonic_now) { @epoch }
          end

          # This test simulates repeated polling. We're trying to prove that the locker
          # will use the previous job's ID as a cursor until the expiry has elapsed,
          # after which we'll reset.
          it "continues lock from previous job id, until cursor expires" do
            @epoch = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expect_to_lock_with(cursor: 0, limit: 1)
            poll
            work(job_1)

            @epoch += 2
            expect_to_lock_with(cursor: job_1[:job_id], limit: 1)
            poll
            work(job_2)

            @epoch += cursor_expiry # our cursor should now expire
            expect_to_lock_with(cursor: 0, limit: 1)
            poll
            work(job_3)
          end
        end
      end
      # rubocop:enable RSpec/SubjectStub
      # rubocop:enable RSpec/InstanceVariable
    end

    context "with run_at_cursor enabled" do
      subject(:locker) do
        described_class.new(
          queue: queue, cursor_expiry: 60, job_buffer: job_buffer, run_at_cursor: true,
        )
      end

      let(:buffer_size) { 1 }
      let!(:job_1) { FakeJob.enqueue(1, queue: queue, priority: 1).attrs }

      before do
        allow(Process).to receive(:clock_gettime).and_return(0)
        locker.instance_variable_get(:@queue_expires_at)[queue] = 60
      end

      it "advances the run_at cursor to the last locked job's run_at after locking" do
        expect_to_lock_with(cursor: 0, run_at_lower_bound: nil, limit: 1)
        poll
        work(job_1)

        expect_to_lock_with(cursor: job_1[:job_id], run_at_lower_bound: job_1[:run_at], limit: 1)
        poll
      end

      it "resets both cursors when the expiry elapses" do
        expect_to_lock_with(cursor: 0, run_at_lower_bound: nil, limit: 1)
        poll
        work(job_1)

        allow(Process).to receive(:clock_gettime).and_return(61)

        expect_to_lock_with(cursor: 0, run_at_lower_bound: nil, limit: 1)
        poll
      end
    end

    context "with run_at_cursor disabled (default)" do
      let(:buffer_size) { 1 }
      let!(:job_1) { FakeJob.enqueue(1, queue: queue, priority: 1).attrs }
      let(:cursor_expiry) { 60 }

      before do
        allow(Process).to receive(:clock_gettime).and_return(0)
        locker.instance_variable_get(:@queue_expires_at)[queue] = 60
      end

      it "always passes nil as the run_at lower bound regardless of jobs worked" do
        expect_to_lock_with(cursor: 0, run_at_lower_bound: nil, limit: 1)
        poll
        work(job_1)

        expect_to_lock_with(cursor: job_1[:job_id], run_at_lower_bound: nil, limit: 1)
        poll
      end
    end
  end

  describe "existence re-check (pg locks don't obey MVCC)" do
    let!(:job_1) { FakeJob.enqueue(1, queue: queue, priority: 1).attrs }

    it "unlocks and excludes jobs that no longer exist by the time the lock is taken" do
      # Simulate the race: the row was destroyed between being scanned and being locked,
      # by having the existence re-check come back empty for a job the lock query returned.
      allow(Que).to receive(:execute).and_call_original
      allow(Que).to receive(:execute).
        with(:check_jobs_batch, ["{#{job_1[:job_id]}}"]).
        and_return([])

      expect(Que).to receive(:execute).with(:unlock_job, [job_1[:job_id]]).and_call_original

      locker.send(:poll)

      expect(job_buffer.size).to eq(0)
    end
  end

  describe "#healthy?" do
    it "is true before any poll has happened" do
      expect(locker).to be_healthy
    end

    it "is true after a poll finds nothing" do
      locker.send(:poll)
      expect(locker).to be_healthy
    end

    it "is false after a postgres error" do
      allow(Que).to receive(:execute).
        with(:lock_jobs_batch, [queue, 0, nil, buffer_size, "{}"]).
        and_raise(PG::Error)
      locker.send(:poll)
      expect(locker).to_not be_healthy
    end
  end
end
