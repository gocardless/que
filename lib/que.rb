# frozen_string_literal: true

require "socket" # For hostname

require_relative "que/adapters/base"
require_relative "que/job"
require_relative "que/job_timeout_error"
require_relative "que/locker"
require_relative "que/migrations"
require_relative "que/sql"
require_relative "que/version"
require_relative "que/worker"
require_relative "que/worker_group"
require_relative "que/middleware/worker_collector"
require_relative "que/middleware/queue_collector"

module Que
  class << self
    attr_accessor :error_handler, :mode, :adapter
    attr_writer :logger

    def execute(statement, binds = [])
      result = adapter.connection.exec_query(
        adapter.send(:sanitize_sql_array, [statement, *binds]),
      )
      columns = result.columns.map(&:to_sym)
      result.cast_values.map { |row| Hash[columns.zip(Array(row))] }
    end

    def transaction(&block)
      adapter.connection.transaction(&block)
    end

    def clear!
      execute "DELETE FROM que_jobs"
    end

    def job_stats
      execute :job_stats
    end

    def worker_states
      execute :worker_states
    end

    # Give us a cleaner interface when specifying a job_class as a string.
    def enqueue(*args)
      Job.enqueue(*args)
    end

    def db_version
      Migrations.db_version
    end

    def migrate!(version = {:version => Migrations::CURRENT_VERSION})
      Migrations.migrate!(version)
    end

    # Have to support create! and drop! in old migrations. They just created
    # and dropped the bare table.
    def create!
      migrate! :version => 1
    end

    def drop!
      migrate! :version => 0
    end

    def logger
      @logger.respond_to?(:call) ? @logger.call : @logger
    end

    def constantize(camel_cased_word)
      if camel_cased_word.respond_to?(:constantize)
        # Use ActiveSupport's version if it exists.
        camel_cased_word.constantize
      else
        camel_cased_word.split('::').inject(Object, &:const_get)
      end
    end
  end
end
