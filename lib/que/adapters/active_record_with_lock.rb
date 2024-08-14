# frozen_string_literal: true

module Que
  module Adapters
    class ActiveRecordWithLock < Que::Adapters::ActiveRecord
      def initialize(job_connection_pool:, lock_connection_pool:)
        @job_connection_pool = job_connection_pool
        @lock_connection_pool = lock_connection_pool
        super
      end

      def checkout_activerecord_adapter(&block)
        checkout_lock_database_connection do
          @job_connection_pool.with_connection(&block)
        end
      end

      def checkout_lock_database_connection(&block)
        @lock_connection_pool.with_connection(&block)
      end

      def execute(command, params = [])
        case command
        when :lock_job
          queue, cursor = params
          lock_job_with_lock_database(queue, cursor)
        when :unlock_job
          job_id = params[0]
          unlock_job(job_id)
        else
          super
        end
      end

      def lock_job_with_lock_database(queue, cursor)
        result = []
        loop do
          result = Que.execute(:find_job_to_lock, [queue, cursor])

          break if result.empty?

          cursor = result.first["job_id"]
          break if pg_try_advisory_lock?(cursor)
        end
        result
      end

      def pg_try_advisory_lock?(job_id)
        checkout_lock_database_connection do |conn|
          conn.execute(
            "SELECT pg_try_advisory_lock(#{job_id})",
          ).try(:first)&.fetch("pg_try_advisory_lock")
        end
      end

      def unlock_job(job_id)
        # If for any reason the connection that is used to get this advisory lock
        # is corrupted, the lock on this job_id would already be released when the
        # connection holding the lock goes bad.
        # Now, if a new connection tries to release the non existing lock this would just no op
        # by returning false and return a warning "WARNING:  you don't own a lock of type ExclusiveLock"
        checkout_lock_database_connection do |conn|
          conn.execute("SELECT pg_advisory_unlock(#{job_id})")
        end
      end
    end
  end
end
