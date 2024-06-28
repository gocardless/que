# frozen_string_literal: true

# https://github.com/que-rb/que/blob/80d6067861a41766c3adb7e29b230ce93d94c8a4/lib/que/active_job/extensions.rb
module Que
    module Adapters
      class ActiveRecordWithLock < Que::Adapters::ActiveRecord
        attr_accessor :job_connection_pool, :lock_connection
        def initialize(job_connection_pool:, lock_connection:)
            @job_connection_pool = job_connection_pool
            @lock_connection = lock_connection
            super
        end

        def checkout_activerecord_adapter(&block)
            @job_connection_pool.with_connection(&block)
        end

        def lock_database_connection
            Thread.current[:db_connection] ||= @lock_connection.connection
        end

        def execute(command, params=[])
            case command
            when :lock_job then
                queue, cursor = params
                lock_job_with_lock_database(queue, cursor)
            when :unlock_job then
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
                cursor = result.first['job_id']
                if pg_try_advisory_lock?(cursor)
                    break
                 end
            end
            return result
        end

        def cleanup!
            @job_connection_pool.release_connection
            @lock_connection.release_connection
        end

        def pg_try_advisory_lock?(job_id)
            lock_database_connection.execute("SELECT pg_try_advisory_lock(#{job_id})").try(:first)&.fetch('pg_try_advisory_lock')
        end

        def unlock_job(job_id)
            lock_database_connection.execute("SELECT pg_advisory_unlock(#{job_id})")
        end
      end
    end
end