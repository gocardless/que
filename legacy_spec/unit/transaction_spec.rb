# frozen_string_literal: true

require 'spec_helper'

describe Kent, '.transaction' do
  it "should use a transaction to rollback changes in the event of an error" do
    proc do
      Kent.transaction do
        Kent.execute "DROP TABLE que_jobs"
        Kent.execute "invalid SQL syntax"
      end
    end.should raise_error(PG::Error)

    DB.table_exists?(:kent_jobs).should be true
  end

  unless RUBY_VERSION.start_with?('1.9')
    it "should rollback correctly in the event of a killed thread" do
      q = Queue.new

      t = Thread.new do
        Kent.transaction do
          Kent.execute "DROP TABLE que_jobs"
          q.push :go!
          sleep
        end
      end

      q.pop
      t.kill
      t.join

      DB.table_exists?(:kent_jobs).should be true
    end
  end
end
