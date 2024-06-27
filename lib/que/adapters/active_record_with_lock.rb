# frozen_string_literal: true

# https://github.com/que-rb/que/blob/80d6067861a41766c3adb7e29b230ce93d94c8a4/lib/que/active_job/extensions.rb
module Que
    module Adapters
      class ActiveRecordWithLock < Que::Adapters::ActiveRecord
        attr_accessor :job_connection_pool, :lock_connection_pool
        def initialize(job_connection_pool:, lock_connection_pool:)
            @job_connection_pool = job_connection_pool
            @lock_connection_pool = lock_connection_pool
            super
        end

        def checkout_activerecord_adapter(&block)
            @job_connection_pool.with_connection(&block)
        end

        def checkout_lock_database_connection
            # when multiple threads are running we need to make sure
            # the acquiring and releasing of advisory locks is done by the 
            # same connection
            Thread.current[:db_connection] ||= lock_connection_pool.checkout
        end

        def lock_database_connection
            Thread.current[:db_connection]
        end

        def release_lock_database_connection
            @lock_connection_pool.checkin(Thread.current[:db_connection])
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
            result = Que.execute(:find_job_to_lock, [queue, cursor])
            return result if result.empty?
         
             if pg_try_advisory_lock?(result.first['job_id'])
                return result
             end
           
            # continue the recursion to fetch the next available job
            lock_job_with_lock_database(queue, result.first['job_id'])
        end

        def cleanup!
            @job_connection_pool.release_connection
            @lock_connection_pool.release_connection
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