# frozen_string_literal: true

# https://github.com/que-rb/que/blob/80d6067861a41766c3adb7e29b230ce93d94c8a4/lib/que/active_job/extensions.rb
module Que
    module Adapters
      class Yugabyte < Que::Adapters::ActiveRecord
        def initialize
            super
        end

        def checkout_activerecord_adapter(&block)
            YugabyteRecord.connection_pool.with_connection(&block)
        end

        def checkout_lock_database_connection
            # when multiple threads are running we need to make sure
            # the acquiring and releasing of advisory locks is done by the 
            # same connection
            Thread.current[:db_connection] ||= LockDatabaseRecord.connection_pool.checkout
        end

        def lock_database_connection
            Thread.current[:db_connection]
        end

        def release_lock_database_connection
            LockDatabaseRecord.connection_pool.checkin(Thread.current[:db_connection])
        end

        def execute(command, params=[])
            if command == :lock_job
                queue, cursor = params
                lock_job_with_lock_database(queue, cursor)
            elsif command == :unlock_job
                job_id = params[0]
                unlock_job(job_id)
            else
                super(command, params)
            end
        end

        def lock_job_with_lock_database(queue, cursor)            
            result = Que.execute(:find_job_to_lock, [queue, cursor])
            return result if result.empty?
         
             if locked?(result.first['job_id'])
                return result
             end
           
            # continue the recursion to fetch the next available job
            lock_job_with_lock_database(queue, result.first['job_id'])
        end

        def cleanup!
            YugabyteRecord.connection_pool.release_connection
            LockDatabaseRecord.connection_pool.release_connection
        end

        def locked?(job_id)
            lock_database_connection.execute("SELECT pg_try_advisory_lock(#{job_id})").try(:first)&.fetch('pg_try_advisory_lock')
        end

        def unlock_job(job_id)
           lock_database_connection.execute("SELECT pg_advisory_unlock(#{job_id})")
        end
      end
    end
end