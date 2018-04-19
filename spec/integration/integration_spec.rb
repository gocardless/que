# frozen_string_literal: true

require "spec_helper"

RSpec.describe "multiple workers" do
  def with_workers(n)
    workers = Array.new(n) { Que::Worker.new(wake_interval: 0.1) }
    worker_threads = workers.map { |worker| Thread.new { worker.work_loop } }
    worker_threads.each { |t| t.abort_on_exception = true }

    yield

    workers.each(&:stop!)
    worker_threads.each do |thread|
      raise "timed out waiting for worker to finish!" unless thread.join(5)
    end
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
end
