# frozen_string_literal: true

module Que
  module Adapters
    class ActiveRecordWithLock < Que::Adapters::ActiveRecord
      METRICS = [
        FindJobSecondsTotal = Prometheus::Client::Counter.new(
          :que_find_job_seconds_total,
          docstring: "Seconds spent finding a job",
          labels: %i[queue],
        ),

        FindJobHitTotal = Prometheus::Client::Counter.new(
          :que_find_job_hit_total,
          docstring: "total number of job hit and misses when acquiring a lock",
          labels: %i[queue job_hit],
        ),
      ].freeze

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

      # This method continues looping through the que_jobs table until it either
      # locks a job successfully or determines that there are no jobs to process.
      def lock_job_with_lock_database(queue, cursor)
        loop do
          observe(duration_metric: FindJobSecondsTotal, labels: { queue: queue }) do
            Que.transaction do
              job_to_lock = Que.execute(:find_job_to_lock, [queue, cursor])
              return job_to_lock if job_to_lock.empty?

              cursor = job_to_lock.first["job_id"]
              job_locked = pg_try_advisory_lock?(cursor)

              observe(count_metric: FindJobHitTotal, labels: { queue: queue, job_hit: job_locked })
              return job_to_lock if job_locked
            end
          end
        end
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

      def observe(count_metric: nil, duration_metric: nil, labels: {})
        now = monotonic_now
        yield if block_given?
      ensure
        count_metric&.increment(labels: labels)
        duration_metric&.increment(
          by: monotonic_now - now,
          labels: labels,
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
