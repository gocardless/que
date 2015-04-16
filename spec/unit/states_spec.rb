require 'spec_helper'

describe Que, '.worker_states' do
  it "should return a list of the job types in the queue, their counts and the number of each currently running" do
    Que.adapter = QUE_ADAPTERS[:connection_pool]

    class WorkerStateJob < BlockJob
      def run
        $pid = Que.execute("select pg_backend_pid()").first[:pg_backend_pid]
        super
      end
    end

    WorkerStateJob.enqueue :priority => 2

    # Ensure that the portion of the SQL query that accounts for bigint
    # job_ids functions correctly.
    DB[:que_jobs].update(:job_id => 2**33)

    t = Thread.new { Que::Job.work }
    $q1.pop

    states = Que.worker_states
    states.length.should be 1

    $q2.push nil
    t.join

    state = states.first
    state.keys.should == %w(priority run_at job_id job_class args error_count last_error queue retryable failed_at pg_backend_pid pg_state pg_state_changed_at pg_last_query pg_last_query_started_at pg_transaction_started_at pg_waiting_on_lock)

    state[:priority].should == 2
    state[:run_at].should be_within(3).of Time.now
    state[:job_id].should == 2**33
    state[:job_class].should == 'WorkerStateJob'
    state[:args].should == []
    state[:error_count].should == 0
    state[:last_error].should be nil

    state[:pg_backend_pid].should == $pid
    state[:pg_state].should == 'idle'
    state[:pg_state_changed_at].should be_within(3).of Time.now
    state[:pg_last_query].should == 'select pg_backend_pid()'
    state[:pg_last_query_started_at].should be_within(3).of Time.now
    state[:pg_transaction_started_at].should == nil
    state[:pg_waiting_on_lock].should == false
  end if QUE_ADAPTERS[:connection_pool]
end
