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

        # def establish_lock_database_connection
        #     Thread.current["lock_database_connection_#{Thread.current.__id__}"] = LockDatabaseRecord.connection
        # end

        # def lock_database_connection
        #     # connection =  @lock_database_connection[Thread.current.name]
        #     # return connection unless connection.nil?
        #     # @lock_database_connection[Thread.current.name] = LockDatabaseRecord.connection
        #     @lock_database_connection ||= LockDatabaseRecord.connection
        # end

        def setup_lock_database_connection
            ::LockDatabaseRecord.connection 
        end

        # def execute(command, params=[])
        #     if command == :lock_job
        #         queue, cursor, lock_database_connection = params
        #         lock_job_with_lock_database(queue, cursor, lock_database_connection)
        #     elsif command == :unlock_job
        #         job_id, lock_database_connection = params
        #         unlock_job(job_id, lock_database_connection)
        #     else
        #         super(command, params)
        #     end
        # end

        def lock_job_with_lock_database(queue, cursor, lock_database_connection)
            query = QueJob.select(:job_id, :queue, :priority, :run_at, :job_class, :retryable, :args, :error_count)
                        .select("extract(epoch from (now() - run_at)) as latency")
                        .where("queue = ? AND job_id >= ? AND run_at <= ?", queue, cursor, Time.now)
                        .where(retryable: true)
                        .order(:priority, :run_at, :job_id)
                        .limit(1).to_sql

            result = Que.execute(query)
            return result if result.empty?
         
             if locked?(result.first['job_id'], lock_database_connection)
                return result
             end
           
            # continue the recursion to fetch the next available job
            lock_job_with_lock_database(queue, result.first['job_id'], lock_database_connection)
        end

        def cleanup!
            YugabyteRecord.connection_pool.release_connection
            LockDatabaseRecord.connection_pool.release_connection
        end

        def locked?(job_id, lock_database_connection)
          lock_database_connection.execute("SELECT pg_try_advisory_lock(#{job_id})").first["pg_try_advisory_lock"]
        end

        def unlock_job(job_id, lock_database_connection)
           lock_database_connection.execute("SELECT pg_advisory_unlock(#{job_id})")
        end
      end
    end
end