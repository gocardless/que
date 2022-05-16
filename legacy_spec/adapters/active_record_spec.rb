# frozen_string_literal: true

# Don't run these specs in JRuby until jruby-pg is compatible with ActiveRecord.
unless defined?(RUBY_ENGINE) && RUBY_ENGINE == 'jruby'

  require 'spec_helper'
  require 'active_record'

  if ActiveRecord.version.release >= Gem::Version.new('4.2') && ActiveRecord.version.release < Gem::Version.new('5.0')
    ActiveRecord::Base.raise_in_transactional_callbacks = true
  end
  ActiveRecord::Base.establish_connection(KENT_URL)

  Kent.connection = ActiveRecord
  KENT_ADAPTERS[:active_record] = Kent.adapter

  describe "Kent using the ActiveRecord adapter" do
    before { Kent.adapter = KENT_ADAPTERS[:active_record] }

    it_behaves_like "a multi-threaded Kent adapter"

    it "should use the same connection that ActiveRecord does" do
      begin
        class ActiveRecordJob < Kent::Job
          def run
            $pid1 = Integer(Kent.execute("select pg_backend_pid()").first['pg_backend_pid'])
            $pid2 = Integer(ActiveRecord::Base.connection.select_value("select pg_backend_pid()"))
          end
        end

        ActiveRecordJob.enqueue
        Kent::Job.work

        $pid1.should == $pid2
      ensure
        $pid1 = $pid2 = nil
      end
    end

    context "if the connection goes down and is reconnected" do
      before do
        Kent::Job.enqueue
        ActiveRecord::Base.connection.reconnect!
      end

      it "should recreate the prepared statements" do
        expect { Kent::Job.enqueue }.not_to raise_error

        DB[:kent_jobs].count.should == 2
      end

      it "should work properly even in a transaction" do
        ActiveRecord::Base.transaction do
          expect { Kent::Job.enqueue }.not_to raise_error
        end

        DB[:kent_jobs].count.should == 2
      end

      it "should log this extraordinary event" do
        $logger.messages.clear
        Kent::Job.enqueue
        $logger.messages.count.should == 1
        message = JSON.load($logger.messages.first)
        message['lib'].should == 'que'
        message['event'].should == 'reprepare_statement'
        message['name'].should == 'insert_job'
      end
    end

    it "should instantiate args as ActiveSupport::HashWithIndifferentAccess" do
      begin
        # Mimic the setting in the Railtie.
        Kent.json_converter = :with_indifferent_access.to_proc

        ArgsJob.enqueue :param => 2
        Kent::Job.work
        $passed_args.first[:param].should == 2
        $passed_args.first.should be_an_instance_of ActiveSupport::HashWithIndifferentAccess
      ensure
        Kent.json_converter = Kent::INDIFFERENTIATOR
      end
    end

    it "should support Rails' special extensions for times" do
      Kent.mode = :async
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }

      Kent::Job.enqueue :run_at => 1.minute.ago
      DB[:kent_jobs].get(:run_at).should be_within(3).of Time.now - 60

      Kent.wake_interval = 0.005.seconds
      sleep_until { DB[:kent_jobs].empty? }
    end

    it "should wake up a Worker after queueing a job in async mode, waiting for a transaction to commit if necessary" do
      Kent.mode = :async
      Kent.worker_count = 4
      sleep_until { Kent::Worker.workers.all? &:sleeping? }

      # Wakes a worker immediately when not in a transaction.
      Kent::Job.enqueue
      sleep_until { Kent::Worker.workers.all?(&:sleeping?) && DB[:kent_jobs].empty? }

      # Wakes a worker on transaction commit when in a transaction.
      ActiveRecord::Base.transaction do
        Kent::Job.enqueue
        Kent::Worker.workers.each { |worker| worker.should be_sleeping }
      end
      sleep_until { Kent::Worker.workers.all?(&:sleeping?) && DB[:kent_jobs].empty? }

      # Does nothing when in a nested transaction.
      # TODO: ideally this would wake after the outer transaction commits
      if ActiveRecord.version.release >= Gem::Version.new('5.0')
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) do
            Kent::Job.enqueue
            Kent::Worker.workers.each { |worker| worker.should be_sleeping }
          end
        end
      end

      # Do nothing when queueing with a specific :run_at.
      BlockJob.enqueue :run_at => Time.now
      Kent::Worker.workers.each { |worker| worker.should be_sleeping }
    end

    it "should be able to survive an ActiveRecord::Rollback without raising an error" do
      ActiveRecord::Base.transaction do
        Kent::Job.enqueue
        raise ActiveRecord::Rollback, "Call tech support!"
      end
      DB[:kent_jobs].count.should be 0
    end

    it "should be able to tell when it's in an ActiveRecord transaction" do
      Kent.adapter.should_not be_in_transaction
      ActiveRecord::Base.transaction do
        Kent.adapter.should be_in_transaction
      end
    end

    it "should not leak connections to other databases when using ActiveRecord's multiple database support" do
      class SecondDatabaseModel < ActiveRecord::Base
        establish_connection(KENT_URL)
      end

      SecondDatabaseModel.clear_active_connections!
      SecondDatabaseModel.connection_handler.active_connections?.should == false

      class SecondDatabaseModelJob < Kent::Job
        def run(*args)
          SecondDatabaseModel.connection.execute("SELECT 1")
        end
      end

      SecondDatabaseModelJob.enqueue
      Kent::Job.work

      SecondDatabaseModel.connection_handler.active_connections?.should == false
    end
  end
end
