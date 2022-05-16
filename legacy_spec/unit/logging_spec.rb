# frozen_string_literal: true

require 'spec_helper'

describe "Logging" do
  it "by default should record the library and hostname and thread id in JSON" do
    Kent.log :event => "blah", :source => 4
    $logger.messages.count.should be 1

    message = JSON.load($logger.messages.first)
    message['lib'].should == 'que'
    message['hostname'].should == Socket.gethostname
    message['pid'].should == Process.pid
    message['event'].should == 'blah'
    message['source'].should == 4
    message['thread'].should == Thread.current.object_id
  end

  it "should allow a callable to be set as the logger" do
    begin
      # Make sure we can get through a work cycle without a logger.
      Kent.logger = proc { $logger }

      Kent::Job.enqueue
      worker = Kent::Worker.new
      sleep_until { worker.sleeping? }

      DB[:kent_jobs].should be_empty

      worker.stop
      worker.wait_until_stopped

      $logger.messages.count.should be 2
      $logger.messages.map{|m| JSON.load(m)['event']}.should == ['job_worked', 'job_unavailable']
    ensure
      Kent.logger = $logger
    end
  end

  it "should not raise an error when no logger is present" do
    begin
      # Make sure we can get through a work cycle without a logger.
      Kent.logger = nil

      Kent::Job.enqueue
      worker = Kent::Worker.new
      sleep_until { worker.sleeping? }

      DB[:kent_jobs].should be_empty

      worker.stop
      worker.wait_until_stopped
    ensure
      Kent.logger = $logger
    end
  end

  it "should allow the use of a custom log formatter" do
    begin
      Kent.log_formatter = proc { |data| "Logged event is #{data[:event]}" }
      Kent.log :event => 'my_event'
      $logger.messages.count.should be 1
      $logger.messages.first.should == "Logged event is my_event"
    ensure
      Kent.log_formatter = nil
    end
  end

  it "should not log anything if the logging formatter returns falsey" do
    begin
      Kent.log_formatter = proc { |data| false }

      Kent.log :event => "blah"
      $logger.messages.should be_empty
    ensure
      Kent.log_formatter = nil
    end
  end

  it "should use a :level option to set the log level if one exists, or default to info" do
    begin
      Kent.logger = o = Object.new

      def o.method_missing(level, message)
        $level = level
        $message = message
      end

      Kent.log :message => 'one'
      $level.should == :info
      JSON.load($message)['message'].should == 'one'

      Kent.log :message => 'two', :level => 'debug'
      $level.should == :debug
      JSON.load($message)['message'].should == 'two'
    ensure
      Kent.logger = $logger
      $level = $message = nil
    end
  end
end
