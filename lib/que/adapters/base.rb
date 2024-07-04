# frozen_string_literal: true

require "time" # For Time.parse.

module Que
  module Adapters
    autoload :ActiveRecord,   "que/adapters/active_record"
    autoload :ConnectionPool, "que/adapters/connection_pool"
    autoload :PG,             "que/adapters/pg"
    autoload :Pond,           "que/adapters/pond"
    autoload :Sequel,         "que/adapters/sequel"
    autoload :Yugabyte,        "que/adapters/yugabyte"

    class UnavailableConnection < StandardError; end

    class Base
      def initialize(_thing = nil)
        @prepared_statements = {}
      end

      # The only method that adapters really need to implement. Should lock a
      # PG::Connection (or something that acts like a PG::Connection) so that
      # no other threads are using it and yield it to the block. Should also
      # be re-entrant.
      def checkout
        raise NotImplementedError
      end

      # Called after Que has returned its connection to whatever pool it's
      # using.
      def cleanup!; end

      # Called after a job is queued in async mode, to prompt a worker to
      # wake up after the current transaction commits. Not all adapters will
      # implement this.
      def wake_worker_after_commit
        false
      end

      def execute(command, params = [])
        params = params.map do |param|
          case param
          # The pg gem unfortunately doesn't convert fractions of time instances, so cast
          # them to a string.
          when Time then param.strftime("%Y-%m-%d %H:%M:%S.%6N %z")
          when Array, Hash then JSON_MODULE.dump(param)
          else param
          end
        end

        cast_result \
          case command
          when Symbol then execute_prepared(command, params)
          when String then execute_sql(command, params)
          end
      end

      def in_transaction?
        checkout { |conn| conn.transaction_status != ::PG::PQTRANS_IDLE }
      end

      private

      def execute_sql(sql, params)
        args = params.empty? ? [sql] : [sql, params]
        checkout { |conn| conn.async_exec(*args) }
      end

      def execute_prepared(name, params)
        checkout do |conn|
          # Prepared statement errors have the potential to foul up the entire
          # transaction, so if we're in one, err on the side of safety.
          if Que.disable_prepared_statements || in_transaction?
            return execute_sql(SQL[name], params)
          end

          statements = @prepared_statements[conn] ||= {}

          begin
            unless statements[name]
              conn.prepare("que_#{name}", SQL[name])
              prepared_just_now = statements[name] = true
            end

            conn.exec_prepared("que_#{name}", params)
          rescue ::PG::InvalidSqlStatementName => error
            # Reconnections on ActiveRecord can cause the same connection
            # objects to refer to new backends, so recover as well as we can.

            unless prepared_just_now
              Que.logger&.warn event: "reprepare_statement", name: name
              statements[name] = false
              retry
            end

            raise error
          end
        end
      end

      CAST_PROCS = {
        # booleans
        16 => ->(value) {
          case value
          when String then value == "t"
          else !!value
          end
        },
        # bigint
        20 => proc(&:to_i),
        # smallint
        21 => proc(&:to_i),
        # integer
        23 => proc(&:to_i),
        # json
        114 => ->(value) { JSON_MODULE.load(value, create_additions: false) },
        # float
        701 => proc(&:to_f),
        # timestamp with time zone
        1184 => ->(value) {
          case value
          when Time then value
          when String then Time.parse(value)
          else raise "Unexpected time class: #{value.class} (#{value.inspect})"
          end
        },
      }.freeze

      def cast_result(result)
        output = result.to_a

        result.fields.each_with_index do |field, index|
          converter = CAST_PROCS[result.ftype(index)]
          next unless converter

          output.each do |hash|
            unless (value = hash[field]).nil?
              hash[field] = converter.call(value)
            end
          end
        end

        output.map!(&Que.json_converter)
      end
    end
  end
end
