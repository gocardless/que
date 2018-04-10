# frozen_string_literal: true

require 'socket' # For hostname

module Que
  autoload :Adapters,   'que/adapters/base'
  autoload :Job,        'que/job'
  autoload :Migrations, 'que/migrations'
  autoload :SQL,        'que/sql'
  autoload :Version,    'que/version'
  autoload :Worker,     'que/worker'

  begin
    require 'multi_json'
    JSON_MODULE = MultiJson
  rescue LoadError
    require 'json'
    JSON_MODULE = JSON
  end

  HASH_DEFAULT_PROC = proc { |hash, key| hash[key.to_s] if Symbol === key }

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
    attr_writer :logger, :adapter, :log_formatter, :disable_prepared_statements, :json_converter

    def connection=(connection)
      self.adapter =
        if connection.to_s == 'ActiveRecord'
          Adapters::ActiveRecord.new
        else
          case connection.class.to_s
          when 'Sequel::Postgres::Database' then Adapters::Sequel.new(connection)
          when 'ConnectionPool'             then Adapters::ConnectionPool.new(connection)
          when 'PG::Connection'             then Adapters::PG.new(connection)
          when 'Pond'                       then Adapters::Pond.new(connection)
          when 'NilClass'                   then connection
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

    def log(data)
      level = data.delete(:level) || :info
      data = {:lib => 'que', :hostname => Socket.gethostname, :pid => Process.pid, :thread => Thread.current.object_id}.merge(data)

      if (l = logger) && output = log_formatter.call(data)
        l.send level, output
      end
    end

    def logger
      @logger.respond_to?(:call) ? @logger.call : @logger
    end

    def log_formatter
      @log_formatter ||= JSON_MODULE.method(:dump)
    end

    def disable_prepared_statements
      @disable_prepared_statements || false
    end

    def constantize(camel_cased_word)
      if camel_cased_word.respond_to?(:constantize)
        # Use ActiveSupport's version if it exists.
        camel_cased_word.constantize
      else
        camel_cased_word.split('::').inject(Object, &:const_get)
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
          rescue => error
            raise
          ensure
            # Handle a raised error or a killed thread.
            if error || Thread.current.status == 'aborting'
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

    # Copy some of the Worker class' config methods here for convenience.
    [:mode, :mode=, :worker_count, :worker_count=, :wake_interval, :wake_interval=, :priority_threshold, :priority_threshold=, :queue_name, :queue_name=, :wake!, :wake_all!].each do |meth|
      define_method(meth) { |*args| Worker.send(meth, *args) }
    end
  end
end

require 'que/railtie' if defined? Rails::Railtie
