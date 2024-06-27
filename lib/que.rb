# frozen_string_literal: true

require "socket" # For hostname

require_relative "que/adapters/base"
require_relative "que/job"
require_relative "que/job_timeout_error"
require_relative "que/leaky_bucket"
require_relative "que/locker"
require_relative "que/migrations"
require_relative "que/sql"
require_relative "que/version"
require_relative "que/worker"
require_relative "que/worker_group"
require_relative "que/middleware/worker_collector"
require_relative "que/middleware/queue_collector"

module Que
  begin
    require "multi_json"
    JSON_MODULE = MultiJson
  rescue LoadError
    require "json"
    JSON_MODULE = JSON
  end

  HASH_DEFAULT_PROC = proc { |hash, key| hash[key.to_s] if key.is_a?(Symbol) }

  INDIFFERENTIATOR = proc do |object|
    case object
    when Array
      object.each(&INDIFFERENTIATOR)
    when Hash
      object.default_proc = HASH_DEFAULT_PROC
      object.each { |key, value| object[key] = INDIFFERENTIATOR.call(value) }
      object
    else
      object
    end
  end

  SYMBOLIZER = proc do |object|
    case object
    when Hash
      object.keys.each do |key|
        object[key.to_sym] = SYMBOLIZER.call(object.delete(key))
      end
      object
    when Array
      object.map! { |e| SYMBOLIZER.call(e) }
    else
      object
    end
  end

  class << self
    attr_accessor :error_handler
    attr_writer :logger, :adapter, :disable_prepared_statements, :json_converter

    def connection=(connection)
      self.adapter =
        if connection.to_s == "ActiveRecord"
          Adapters::ActiveRecord.new
        else
          case connection.class.to_s
          when "Que::Adapters::ActiveRecordWithLock" then  

            Adapters::ActiveRecordWithLock.new(
              job_connection_pool: connection.job_connection_pool, 
              lock_connection_pool: connection.lock_connection_pool
            )
          when "Sequel::Postgres::Database" then Adapters::Sequel.new(connection)
          when "ConnectionPool"             then Adapters::ConnectionPool.new(connection)
          when "PG::Connection"             then Adapters::PG.new(connection)
          when "Pond"                       then Adapters::Pond.new(connection)
          when "NilClass"                   then connection
          else raise "Que connection not recognized: #{connection.inspect}"
          end
        end
    end

    def adapter
      @adapter || raise("Que connection not established!")
    end

    def execute(*args)
      adapter.execute(*args)
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

    def migrate!(version = { version: Migrations::CURRENT_VERSION })
      Migrations.migrate!(version)
    end

    # Have to support create! and drop! in old migrations. They just created
    # and dropped the bare table.
    def create!
      migrate! version: 1
    end

    def drop!
      migrate! version: 0
    end

    def logger
      @logger.respond_to?(:call) ? @logger.call : @logger
    end

    def disable_prepared_statements
      @disable_prepared_statements || false
    end

    def constantize(camel_cased_word)
      if camel_cased_word.respond_to?(:constantize)
        # Use ActiveSupport's version if it exists.
        camel_cased_word.constantize
      else
        camel_cased_word.split("::").inject(Object, &:const_get)
      end
    end

    # A helper method to manage transactions, used mainly by the migration
    # system. It's available for general use, but if you're using an ORM that
    # provides its own transaction helper, be sure to use that instead, or the
    # two may interfere with one another.
    def transaction
      adapter.checkout do
        if adapter.in_transaction?
          yield
        else
          begin
            execute "BEGIN"
            yield
          rescue StandardError => error
            raise
          ensure
            # Handle a raised error or a killed thread.
            if error || Thread.current.status == "aborting"
              execute "ROLLBACK"
            else
              execute "COMMIT"
            end
          end
        end
      end
    end

    def json_converter
      @json_converter ||= INDIFFERENTIATOR
    end

    attr_accessor :mode
  end
end

require "que/railtie" if defined? Rails::Railtie
