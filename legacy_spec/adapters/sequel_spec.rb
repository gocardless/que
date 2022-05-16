# frozen_string_literal: true

require 'spec_helper'

Kent.connection = SEKENTL_ADAPTER_DB = Sequel.connect(KENT_URL)
KENT_ADAPTERS[:sequel] = Kent.adapter

describe "Kent using the Sequel adapter" do
  before { Kent.adapter = KENT_ADAPTERS[:sequel] }

  it_behaves_like "a multi-threaded Kent adapter"

  it "should use the same connection that Sequel does" do
    begin
      class SequelJob < Kent::Job
        def run
          $pid1 = Integer(Kent.execute("select pg_backend_pid()").first['pg_backend_pid'])
          $pid2 = Integer(SEKENTL_ADAPTER_DB['select pg_backend_pid()'].get)
        end
      end

      SequelJob.enqueue
      Kent::Job.work

      $pid1.should == $pid2
    ensure
      $pid1 = $pid2 = nil
    end
  end

  it "should wake up a Worker after queueing a job in async mode, waiting for a transaction to commit if necessary" do
    Kent.mode = :async
    Kent.worker_count = 4
    sleep_until { Kent::Worker.workers.all? &:sleeping? }

    # Wakes a worker immediately when not in a transaction.
    Kent::Job.enqueue
    sleep_until { Kent::Worker.workers.all?(&:sleeping?) && DB[:kent_jobs].empty? }

    SEKENTL_ADAPTER_DB.transaction do
      Kent::Job.enqueue
      Kent::Worker.workers.each { |worker| worker.should be_sleeping }
    end
    sleep_until { Kent::Worker.workers.all?(&:sleeping?) && DB[:kent_jobs].empty? }

    # Do nothing when queueing with a specific :run_at.
    BlockJob.enqueue :run_at => Time.now
    Kent::Worker.workers.each { |worker| worker.should be_sleeping }
  end

  it "should be able to tell when it's in a Sequel transaction" do
    Kent.adapter.should_not be_in_transaction
    SEKENTL_ADAPTER_DB.transaction do
      Kent.adapter.should be_in_transaction
    end
  end
end
