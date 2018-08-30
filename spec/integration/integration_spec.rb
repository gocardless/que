# frozen_string_literal: true

require "spec_helper"
require "que/worker" # required to prevent autoload races

RSpec.describe "multiple workers" do
  def with_workers(n, stop_timeout: 5)
    Que::Worker.start_workers(n, wake_interval: 0.01).tap { yield }.call(stop_timeout)
  end

  # Wait for a maximum of [timeout] seconds for all jobs to be worked
  def wait_for_jobs_to_be_worked(timeout: 10)
    start = Time.now
    loop do
      break if QueJob.count == 0 || Time.now - start > timeout
      sleep 0.1
    end
  end

  context "with one worker and many jobs" do
    it "works each job exactly once" do
      10.times.map { |i| FakeJob.enqueue(i) }

      expect(QueJob.count).to eq(10)

      with_workers(1) { wait_for_jobs_to_be_worked }

      expect(QueJob.count).to eq(0)
      expect(FakeJob.log.count).to eq(10)
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
      ActiveRecord::Base.connection.execute("CREATE TABLE IF NOT EXISTS users ( name text )")
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
      expect(User.all.map(&:name).sort).to eq(["alice", "bob", "charlie"])
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

      expect(sleep_job).not_to be(nil)
      expect(sleep_job.last_error).to match(/Job exceeded timeout when requested to stop/)
    end
  end

  context "and that job has a rescue-all clause" do
    it "raises Que::JobTimeoutError" do
      RescueSleepJob.enqueue(0.1)

      with_workers(1, stop_timeout: 0.1) { sleep 0.1 }

      rescue_sleep_job = QueJob.last

      expect(rescue_sleep_job).not_to be(nil)
      expect(rescue_sleep_job.last_error).to match(/Job exceeded timeout when requested to stop/)
    end
  end
end
