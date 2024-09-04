# frozen_string_literal: true

require "spec_helper"
require "que/worker" # required to prevent autoload races

# rubocop:disable RSpec/DescribeClass
RSpec.describe "multiple workers" do
  context "with one worker and many jobs" do
    it "works each job exactly once" do
      10.times.each { |i| FakeJob.enqueue(i) }

      expect(QueJob.count).to eq(10)

      with_workers(1) { wait_for_jobs_to_be_worked }

      expect(QueJob.count).to eq(0)
      expect(FakeJob.log.count).to eq(10)
    end
  end

  context "with a job on a non default queue" do
    context "with exclusive workers" do
      it "does not work the job on the non-default queue" do
        FakeJob.enqueue(1, queue: "default")
        FakeJob.enqueue(2, queue: "non-default")

        expect(QueJob.count).to eq(2)

        with_workers(1) { wait_for_jobs_to_be_worked(timeout: 1) }

        expect(QueJob.count).to eq(1)
        expect(FakeJob.log.count).to eq(1)
      end
    end

    context "with permissive workers" do
      it "works each job exactly once" do
        FakeJob.enqueue(1, queue: "default")
        FakeJob.enqueue(2, queue: "non-default")

        expect(QueJob.count).to eq(2)

        with_workers(1, secondary_queues: ["non-default"]) do
          wait_for_jobs_to_be_worked(timeout: 1)
        end

        expect(QueJob.count).to eq(0)
        expect(FakeJob.log.count).to eq(2)
      end

      it "works jobs for defined secondary_queues only" do
        FakeJob.enqueue(1, queue: "default")
        FakeJob.enqueue(2, queue: "non-default")
        FakeJob.enqueue(3, queue: "not-worked")

        expect(QueJob.count).to eq(3)

        with_workers(1, secondary_queues: ["non-default"]) do
          wait_for_jobs_to_be_worked(timeout: 1)
        end

        expect(QueJob.count).to eq(1)
        expect(FakeJob.log.count).to eq(2)
      end
    end
  end

  context "with multiple workers contending over the same job" do
    it "works that job exactly once" do
      FakeJob.enqueue(1)

      expect(QueJob.count).to eq(1)

      with_workers(5) { wait_for_jobs_to_be_worked }

      expect(QueJob.count).to eq(0)
      expect(FakeJob.log.count).to eq(1)
    end
  end

  context "with multiple jobs" do
    around do |example|
      ActiveRecord::Base.connection.execute(
        "CREATE TABLE IF NOT EXISTS users ( name text )",
      )
      User.delete_all
      example.run
      ActiveRecord::Base.connection.execute("DROP TABLE users")
    end

    it "works them all exactly once" do
      CreateUser.enqueue("alice")
      CreateUser.enqueue("bob")
      CreateUser.enqueue("charlie")

      expect(QueJob.count).to eq(3)

      with_workers(5) { wait_for_jobs_to_be_worked }

      expect(QueJob.count).to eq(0)
      expect(User.count).to eq(3)
      expect(User.all.map(&:name).sort).to eq(%w[alice bob charlie])
    end
  end

  context "with jobs that exceed stop timeout" do
    it "raises Que::JobTimeoutError" do
      SleepJob.enqueue(5) # sleep 5s

      # Sleep to let the worker pick-up the SleepJob, then stop the worker with an
      # aggressive timeout. This should cause JobTimeout to be raised in the worker
      # thread.
      with_workers(1, stop_timeout: 0.01) { sleep 0.1 }

      sleep_job = QueJob.last

      expect(sleep_job).to_not be_nil
      expect(sleep_job.last_error).to match(/Job exceeded timeout when requested to stop/)
    end

    context "but is interruptible" do
      it "terminates gracefully" do
        # Sleep for 0.2s before checking if it should continue
        InterruptibleSleepJob.enqueue(0.2)

        # Sleep 0.1s to let the worker pick-up the SleepJob, then stop the worker with a
        # a long enough timeout to let an iteration of sleep complete.
        with_workers(1, stop_timeout: 0.3) { sleep 0.1 }

        expect(QueJob.count).to eq(0)
        expect(InterruptibleSleepJob.log.count).to eq(1)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
