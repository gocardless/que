# frozen_string_literal: true

require 'spec_helper'

describe Kent::Job, '.enqueue' do
  it "should be able to queue a job" do
    DB[:kent_jobs].count.should be 0
    result = Kent::Job.enqueue
    DB[:kent_jobs].count.should be 1

    result.should be_an_instance_of Kent::Job
    result.attrs[:queue].should == ''
    result.attrs[:priority].should == 100
    result.attrs[:args].should == []

    job = DB[:kent_jobs].first
    job[:queue].should == ''
    job[:priority].should be 100
    job[:run_at].should be_within(3).of Time.now
    job[:job_class].should == "Kent::Job"
    JSON.load(job[:args]).should == []
  end

  it "should be aliased to .queue" do
    DB[:kent_jobs].count.should be 0
    suppress_warnings { Kent::Job.queue }
    DB[:kent_jobs].count.should be 1
  end

  it "should be able to queue a job with arguments" do
    DB[:kent_jobs].count.should be 0
    Kent::Job.enqueue 1, 'two'
    DB[:kent_jobs].count.should be 1

    job = DB[:kent_jobs].first
    job[:queue].should == ''
    job[:priority].should be 100
    job[:run_at].should be_within(3).of Time.now
    job[:job_class].should == "Kent::Job"
    JSON.load(job[:args]).should == [1, 'two']
  end

  it "should be able to queue a job with complex arguments" do
    DB[:kent_jobs].count.should be 0
    Kent::Job.enqueue 1, 'two', :string => "string",
                             :integer => 5,
                             :array => [1, "two", {:three => 3}],
                             :hash => {:one => 1, :two => 'two', :three => [3]}

    DB[:kent_jobs].count.should be 1

    job = DB[:kent_jobs].first
    job[:queue].should == ''
    job[:priority].should be 100
    job[:run_at].should be_within(3).of Time.now
    job[:job_class].should == "Kent::Job"
    JSON.load(job[:args]).should == [
      1,
      'two',
      {
        'string' => 'string',
        'integer' => 5,
        'array' => [1, "two", {"three" => 3}],
        'hash' => {'one' => 1, 'two' => 'two', 'three' => [3]}
      }
    ]
  end

  it "should be able to queue a job with a specific time to run" do
    DB[:kent_jobs].count.should be 0
    Kent::Job.enqueue 1, :run_at => Time.now + 60
    DB[:kent_jobs].count.should be 1

    job = DB[:kent_jobs].first
    job[:queue].should == ''
    job[:priority].should be 100
    job[:run_at].should be_within(3).of Time.now + 60
    job[:job_class].should == "Kent::Job"
    JSON.load(job[:args]).should == [1]
  end

  it "should be able to queue a job with a specific priority" do
    DB[:kent_jobs].count.should be 0
    Kent::Job.enqueue 1, :priority => 4
    DB[:kent_jobs].count.should be 1

    job = DB[:kent_jobs].first
    job[:queue].should == ''
    job[:priority].should be 4
    job[:run_at].should be_within(3).of Time.now
    job[:job_class].should == "Kent::Job"
    JSON.load(job[:args]).should == [1]
  end

  it "should be able to queue a job with queueing options in addition to argument options" do
    DB[:kent_jobs].count.should be 0
    Kent::Job.enqueue 1, :string => "string", :run_at => Time.now + 60, :priority => 4
    DB[:kent_jobs].count.should be 1

    job = DB[:kent_jobs].first
    job[:queue].should == ''
    job[:priority].should be 4
    job[:run_at].should be_within(3).of Time.now + 60
    job[:job_class].should == "Kent::Job"
    JSON.load(job[:args]).should == [1, {'string' => 'string'}]
  end

  it "should respect a job class defined as a string" do
    Kent.enqueue 'argument', :queue => 'my_queue', :other_arg => 'other_arg', :job_class => 'MyJobClass'
    Kent::Job.enqueue 'argument', :queue => 'my_queue', :other_arg => 'other_arg', :job_class => 'MyJobClass'

    DB[:kent_jobs].count.should be 2
    DB[:kent_jobs].all.each do |job|
      job[:job_class].should == 'MyJobClass'
      job[:queue].should == 'my_queue'
      JSON.load(job[:args]).should == ['argument', {'other_arg' => 'other_arg'}]
    end
  end

  it "should respect a default (but overridable) priority for the job class" do
    class DefaultPriorityJob < Kent::Job
      @priority = 3
    end

    DB[:kent_jobs].count.should be 0
    DefaultPriorityJob.enqueue 1
    DefaultPriorityJob.enqueue 1, :priority => 4
    DB[:kent_jobs].count.should be 2

    first, second = DB[:kent_jobs].order(:job_id).all

    first[:queue].should == ''
    first[:priority].should be 3
    first[:run_at].should be_within(3).of Time.now
    first[:job_class].should == "DefaultPriorityJob"
    JSON.load(first[:args]).should == [1]

    second[:queue].should == ''
    second[:priority].should be 4
    second[:run_at].should be_within(3).of Time.now
    second[:job_class].should == "DefaultPriorityJob"
    JSON.load(second[:args]).should == [1]
  end

  it "should respect the old @default_priority setting" do
    class OldDefaultPriorityJob < Kent::Job
      @default_priority = 3
    end

    DB[:kent_jobs].count.should be 0
    suppress_warnings do
      OldDefaultPriorityJob.enqueue 1
      OldDefaultPriorityJob.enqueue 1, :priority => 4
    end
    DB[:kent_jobs].count.should be 2

    first, second = DB[:kent_jobs].order(:job_id).all

    first[:queue].should == ''
    first[:priority].should be 3
    first[:run_at].should be_within(3).of Time.now
    first[:job_class].should == "OldDefaultPriorityJob"
    JSON.load(first[:args]).should == [1]

    second[:queue].should == ''
    second[:priority].should be 4
    second[:run_at].should be_within(3).of Time.now
    second[:job_class].should == "OldDefaultPriorityJob"
    JSON.load(second[:args]).should == [1]
  end

  it "should respect a default (but overridable) run_at for the job class" do
    class DefaultRunAtJob < Kent::Job
      @run_at = -> { Time.now + 60 }
    end

    DB[:kent_jobs].count.should be 0
    DefaultRunAtJob.enqueue 1
    DefaultRunAtJob.enqueue 1, :run_at => Time.now + 30
    DB[:kent_jobs].count.should be 2

    first, second = DB[:kent_jobs].order(:job_id).all

    first[:queue].should == ''
    first[:priority].should be 100
    first[:run_at].should be_within(3).of Time.now + 60
    first[:job_class].should == "DefaultRunAtJob"
    JSON.load(first[:args]).should == [1]

    second[:queue].should == ''
    second[:priority].should be 100
    second[:run_at].should be_within(3).of Time.now + 30
    second[:job_class].should == "DefaultRunAtJob"
    JSON.load(second[:args]).should == [1]
  end

  it "should respect the old @default_run_at setting" do
    class OldDefaultRunAtJob < Kent::Job
      @default_run_at = -> { Time.now + 60 }
    end

    DB[:kent_jobs].count.should be 0
    suppress_warnings do
      OldDefaultRunAtJob.enqueue 1
      OldDefaultRunAtJob.enqueue 1, :run_at => Time.now + 30
    end
    DB[:kent_jobs].count.should be 2

    first, second = DB[:kent_jobs].order(:job_id).all

    first[:queue].should == ''
    first[:priority].should be 100
    first[:run_at].should be_within(3).of Time.now + 60
    first[:job_class].should == "OldDefaultRunAtJob"
    JSON.load(first[:args]).should == [1]

    second[:queue].should == ''
    second[:priority].should be 100
    second[:run_at].should be_within(3).of Time.now + 30
    second[:job_class].should == "OldDefaultRunAtJob"
    JSON.load(second[:args]).should == [1]
  end

  it "should respect a default (but overridable) queue for the job class" do
    class NamedQueueJob < Kent::Job
      @queue = :my_queue
    end

    DB[:kent_jobs].count.should be 0
    NamedQueueJob.enqueue 1
    NamedQueueJob.enqueue 1, :queue => 'my_queue_2'
    NamedQueueJob.enqueue 1, :queue => :my_queue_2
    NamedQueueJob.enqueue 1, :queue => ''
    NamedQueueJob.enqueue 1, :queue => nil
    DB[:kent_jobs].count.should be 5

    first, second, third, fourth, fifth = DB[:kent_jobs].order(:job_id).select_map(:queue)

    first.should  == 'my_queue'
    second.should == 'my_queue_2'
    third.should  == 'my_queue_2'
    fourth.should == ''
    fifth.should  == ''
  end
end
