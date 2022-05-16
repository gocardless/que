# frozen_string_literal: true

require 'spec_helper'

describe "Managing the Worker pool" do
  it "should log mode changes" do
    Kent.mode = :sync
    Kent.mode = :off
    Kent.mode = :off

    $logger.messages.count.should be 3
    m1, m2, m3 = $logger.messages.map { |m| JSON.load(m) }

    m1['event'].should == 'mode_change'
    m1['value'].should == 'sync'

    m2['event'].should == 'mode_change'
    m2['value'].should == 'off'

    m3['event'].should == 'mode_change'
    m3['value'].should == 'off'
  end

  describe "Kent.mode=" do
    describe ":off" do
      it "with worker_count 0 should not instantiate workers or hit the db" do
        Kent.connection = nil
        Kent.worker_count = 0
        Kent.mode = :off
        Kent::Worker.workers.should == []
      end

      it "with worker_count > 0 should not instantiate workers or hit the db" do
        Kent.connection = nil
        Kent.mode = :off
        Kent.worker_count = 5
        Kent.mode = :off
        Kent::Worker.workers.should == []
      end
    end

    describe ":sync" do
      it "with worker_count 0 should not instantiate workers or hit the db" do
        Kent.connection = nil
        Kent.worker_count = 0
        Kent.mode = :sync
        Kent::Worker.workers.should == []
      end

      it "with worker_count > 0 should not instantiate workers or hit the db" do
        Kent.connection = nil
        Kent.mode = :sync
        Kent.worker_count = 5
        Kent.mode = :sync
        Kent::Worker.workers.should == []
      end

      it "should make jobs run in the same thread as they are queued" do
        Kent.mode = :sync

        ArgsJob.enqueue(5, :testing => "synchronous").should be_an_instance_of ArgsJob
        $passed_args.should == [5, {"testing" => "synchronous"}]
        DB[:kent_jobs].count.should be 0
      end

      it "should work fine with enqueuing jobs without a DB connection" do
        Kent.connection = nil
        Kent.mode = :sync

        ArgsJob.enqueue(5, :testing => "synchronous").should be_an_instance_of ArgsJob
        $passed_args.should == [5, {"testing" => "synchronous"}]
      end

      it "should not affect jobs that are queued with specific run_ats" do
        Kent.mode = :sync

        ArgsJob.enqueue(5, :testing => "synchronous", :run_at => Time.now + 60)
        DB[:kent_jobs].select_map(:job_class).should == ["ArgsJob"]
      end
    end

    describe ":async" do
      it "with worker_count 0 should not instantiate workers or hit the db" do
        Kent.connection = nil
        Kent.worker_count = 0
        Kent.mode = :async
        Kent::Worker.workers.map{|w| [w.state, w.thread.status]}.should == []
      end

      it "with worker_count > 0 should instantiate workers and hit the db" do
        Kent::Job.enqueue
        Kent.worker_count = 5
        Kent.mode = :async
        sleep_until { Kent::Worker.workers.all? &:sleeping? }
        DB[:kent_jobs].count.should == 0
        Kent::Worker.workers.map{|w| [w.state, w.thread.status]}.should == [[:sleeping, 'sleep']] * 5
      end

      it "should wake a worker every Kent.wake_interval seconds" do
        Kent.worker_count = 4
        Kent.mode = :async
        sleep_until { Kent::Worker.workers.all? &:sleeping? }
        Kent.wake_interval = 0.01 # 10 ms
        Kent::Job.enqueue
        sleep_until { DB[:kent_jobs].count == 0 }
      end

      it "should work jobs in the queue defined by the Kent.queue_name config option" do
        begin
          Kent::Job.enqueue 1
          Kent::Job.enqueue 2, :queue => 'my_queue'

          Kent.queue_name = 'my_queue'

          Kent.mode = :async
          Kent.worker_count = 2

          sleep_until { Kent::Worker.workers.all? &:sleeping? }
          DB[:kent_jobs].count.should be 1

          job = DB[:kent_jobs].first
          job[:queue].should == ''
          job[:args].should == '[1]'
        ensure
          Kent.queue_name = nil
        end
      end
    end
  end

  describe "Kent.worker_count=" do
    describe "when the mode is :off" do
      it "should record the setting but not instantiate any workers" do
        Kent.worker_count.should == 0
        Kent.connection = nil
        Kent.mode = :off
        Kent::Worker.workers.should == []

        Kent.worker_count = 4
        Kent.worker_count.should == 4
        Kent::Worker.workers.should == []

        Kent.worker_count = 6
        Kent.worker_count.should == 6
        Kent::Worker.workers.should == []

        Kent.worker_count = 2
        Kent.worker_count.should == 2
        Kent::Worker.workers.should == []

        Kent.worker_count = 0
        Kent.worker_count.should == 0
        Kent::Worker.workers.should == []
      end
    end

    describe "when the mode is :sync" do
      it "should record the setting but not instantiate any workers" do
        Kent.worker_count.should == 0
        Kent.connection = nil
        Kent.mode = :sync
        Kent::Worker.workers.should == []

        Kent.worker_count = 4
        Kent.worker_count.should == 4
        Kent::Worker.workers.should == []

        Kent.worker_count = 6
        Kent.worker_count.should == 6
        Kent::Worker.workers.should == []

        Kent.worker_count = 2
        Kent.worker_count.should == 2
        Kent::Worker.workers.should == []

        Kent.worker_count = 0
        Kent.worker_count.should == 0
        Kent::Worker.workers.should == []
      end
    end

    describe "when the mode is :async" do
      it "should start hitting the DB when transitioning to a non-zero value" do
        Kent.mode = :async
        Kent::Job.enqueue
        Kent.worker_count = 4
        sleep_until { Kent::Worker.workers.all?(&:sleeping?) }
        Kent::Worker.workers.map{|w| [w.state, w.thread.status]}.should == [[:sleeping, 'sleep']] * 4
        DB[:kent_jobs].count.should == 0
      end

      it "should stop hitting the DB when transitioning to zero" do
        Kent.mode = :async
        Kent.worker_count = 4
        sleep_until { Kent::Worker.workers.all?(&:sleeping?) }
        Kent.connection = nil
        Kent.worker_count = 0
        $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
          [['mode_change', 'async'], ['worker_count_change', '4']] + [['job_unavailable', nil]] * 4 + [['worker_count_change', '0']]
      end

      it "should be able to scale down the number of workers gracefully" do
        Kent.mode = :async
        Kent.worker_count = 4

        workers = Kent::Worker.workers.dup
        workers.count.should be 4
        sleep_until { Kent::Worker.workers.all?(&:sleeping?) }

        Kent.worker_count = 2
        Kent::Worker.workers.count.should be 2
        sleep_until { Kent::Worker.workers.all?(&:sleeping?) }

        workers[0..1].should == Kent::Worker.workers
        workers[2..3].each do |worker|
          worker.should be_an_instance_of Kent::Worker
          worker.thread.status.should == false
        end

        $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
          [['mode_change', 'async'], ['worker_count_change', '4']] + [['job_unavailable', nil]] * 4 + [['worker_count_change', '2']]
      end

      it "should be able to scale up the number of workers gracefully" do
        Kent.mode = :async
        Kent.worker_count = 4
        workers = Kent::Worker.workers.dup
        workers.count.should be 4

        sleep_until { Kent::Worker.workers.all?(&:sleeping?) }
        Kent.worker_count = 6
        Kent::Worker.workers.count.should be 6
        sleep_until { Kent::Worker.workers.all?(&:sleeping?) }

        workers.should == Kent::Worker.workers[0..3]

        $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
          [['mode_change', 'async'], ['worker_count_change', '4']] + [['job_unavailable', nil]] * 4 + [['worker_count_change', '6']] + [['job_unavailable', nil]] * 2
      end
    end
  end

  describe "Kent.wake!" do
    it "when mode = :off should do nothing" do
      Kent.connection = nil
      Kent.mode = :off
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      Kent.wake!
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
        [['mode_change', 'off'], ['worker_count_change', '4']]
    end

    it "when mode = :sync should do nothing" do
      Kent.connection = nil
      Kent.mode = :sync
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      Kent.wake!
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
        [['mode_change', 'sync'], ['worker_count_change', '4']]
    end

    it "when mode = :async and worker_count = 0 should do nothing" do
      Kent.connection = nil
      Kent.mode = :async
      Kent.worker_count = 0
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      Kent.wake!
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
        [['mode_change', 'async'], ['worker_count_change', '0']]
    end

    it "when mode = :async and worker_count > 0 should wake up a single worker" do
      Kent.mode = :async
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }

      BlockJob.enqueue
      Kent.wake!

      $q1.pop
      Kent::Worker.workers.first.should be_working
      Kent::Worker.workers[1..3].each { |w| w.should be_sleeping }
      DB[:kent_jobs].count.should be 1
      $q2.push nil

      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      DB[:kent_jobs].count.should be 0
    end

    it "when mode = :async and worker_count > 0 should be thread-safe" do
      Kent.mode = :async
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      threads = 4.times.map { Thread.new { 100.times { Kent.wake! } } }
      threads.each(&:join)
    end
  end

  describe "Kent.wake_all!" do
    it "when mode = :off should do nothing" do
      Kent.connection = nil
      Kent.mode = :off
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      Kent.wake_all!
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
        [['mode_change', 'off'], ['worker_count_change', '4']]
    end

    it "when mode = :sync should do nothing" do
      Kent.connection = nil
      Kent.mode = :sync
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      Kent.wake_all!
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
        [['mode_change', 'sync'], ['worker_count_change', '4']]
    end

    it "when mode = :async and worker_count = 0 should do nothing" do
      Kent.connection = nil
      Kent.mode = :async
      Kent.worker_count = 0
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      Kent.wake_all!
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      $logger.messages.map{|m| JSON.load(m).values_at('event', 'value')}.should ==
        [['mode_change', 'async'], ['worker_count_change', '0']]
    end

    # This spec requires at least four connections.
    it "when mode = :async and worker_count > 0 should wake up all workers" do
      Kent.adapter = KENT_ADAPTERS[:pond]

      Kent.mode = :async
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }

      4.times { BlockJob.enqueue }
      Kent.wake_all!
      4.times { $q1.pop }

      Kent::Worker.workers.each{ |worker| worker.should be_working }
      4.times { $q2.push nil }

      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      DB[:kent_jobs].count.should be 0
    end if KENT_ADAPTERS[:pond]

    it "when mode = :async and worker_count > 0 should be thread-safe" do
      Kent.mode = :async
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }
      threads = 4.times.map { Thread.new { 100.times { Kent.wake_all! } } }
      threads.each(&:join)
    end
  end
end
