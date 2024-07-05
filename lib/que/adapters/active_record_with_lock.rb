# frozen_string_literal: true

# https://github.com/que-rb/que/blob/80d6067861a41766c3adb7e29b230ce93d94c8a4/lib/que/active_job/extensions.rb
module Que
  module Adapters
    class ActiveRecordWithLock < Que::Adapters::ActiveRecord
      def initialize(job_connection_pool:, lock_record:)
        @job_connection_pool = job_connection_pool
        @lock_record = lock_record
        super
      end

      def checkout_activerecord_adapter(&block)
        @job_connection_pool.with_connection(&block)
      end

      def lock_database_connection
        if Thread.current[:db_connection]
          return Thread.current[:db_connection] if Thread.current[:db_connection].active?
        end
        # We are storing this in thread variable here to make sure
        # same connection is used to acquire and release the advisory locks.
        # Advisory lock will not be released if any other connection from the
        # pool tries to release the lock
        Thread.current[:db_connection] = @lock_record.connection
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
          super(command, params)
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

      def cleanup!
        @job_connection_pool.release_connection
        @lock_record.remove_connection
      end

      def pg_try_advisory_lock?(job_id)
        lock_database_connection.execute(
          "SELECT pg_try_advisory_lock(#{job_id})",
        ).try(:first)&.fetch("pg_try_advisory_lock")
      end

      def unlock_job(job_id)
        # If for any reason the connection that is used to get this advisory lock
        # is corrupted, the lock on this job_id would already be released when the
        # connection holding the lock goes bad.
        # Now, if a new connection tries to release the non existing lock this would just no op
        # by returning false and return a warning "WARNING:  you don't own a lock of type ExclusiveLock"
        lock_database_connection.execute("SELECT pg_advisory_unlock(#{job_id})")
      end
    end
  end
end
