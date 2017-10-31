# frozen_string_literal: true

require "spec_helper"

RSpec.describe "multiple workers" do
  # Spawn a single Que worker in a separate process
  # It will exit cleanly when sent SIGTERM or if it becomes an orphan process
  # (i.e. our spec process dies)
  def create_worker
    fork do
      # If this process becomes orphaned, it should stop que and exit
      Thread.new { loop { worker.stop! && Kernel.exit! if Process.ppid == 1; sleep 1 } }
      establish_database_connection
      worker = Que::Worker.new
      trap("TERM") { worker.stop! }
      worker.work_loop
    end
  end

  # Spawn multiple workers, ensuring they don't inherit our database connectino
  def create_workers(n)
    # We don't want the child processes to inherit our db connection, since they'll
    # close it when they exit and we'll no longer be able to use it.
    ActiveRecord::Base.connection.disconnect!
    workers = n.times.map { create_worker }
    establish_database_connection
    workers
  end

  def with_workers(n)
    workers = create_workers(n)
    yield
    workers.each { |pid| Process.kill("TERM", pid) }
    Process.waitall
  end

  # Wait for a maximum of [timeout] seconds for all jobs to be worked
  def wait_for_jobs_to_be_worked(timeout: 10)
    start = Time.now
    loop do
      break if QueJob.count == 0 || Time.now - start > timeout
      sleep 0.5
    end
  end


  it "works jobs" do
    FakeJob.enqueue(1)

    expect(QueJob.count).to eq(1)

    with_workers(5) { wait_for_jobs_to_be_worked }

    expect(QueJob.count).to eq(0)
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
