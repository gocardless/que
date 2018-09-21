# frozen_string_literal: true

require "prometheus/client"

module Que
  # The Locker is used to acquire a job from the Postgres jobs table. The only method we
  # expose is with_locked_job, as we want to ensure that callers safely unlock their jobs.
  #
  # For performance, the locker keeps track of the last job ID it locked, and uses that
  # job's ID to begin the next attempt to acquire a job. There is a point where the
  # performance of lock acquisition goes off a cliff, and using the previous job's ID
  # delays the point at which that occurs.
  #
  # For more information, see the 'Predicate Specificity' chapter of:
  # https://brandur.org/postgres-queues
  class Locker
    METRICS = [
      ExistsTotal = Prometheus::Client::Counter.new(
        :que_locker_exists_total, "Counter of attempts to check job existence before locking",
      ),
      ExistsSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_exists_seconds_total, "Seconds spent checking job exists before locking",
      ),
      UnlockTotal = Prometheus::Client::Counter.new(
        :que_locker_unlock_total, "Counter of attempts to unlock job advisory locks",
      ),
      UnlockSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_unlock_seconds_total, "Seconds spent unlocking job advisory locks",
      ),
      AcquireTotal = Prometheus::Client::Counter.new(
        :que_locker_acquire_total, "Counter of number of job lock queries executed",
      ),
      AcquireSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_acquire_seconds_total, "Seconds spent running job lock query",
      ),
    ]

    def initialize(queue:, cursor_expiry:)
      @queue = queue
      @cursor_expiry = cursor_expiry
      @cursor = 0
      @cursor_expires_at = monotonic_now
    end

    # Acquire a job for the period of running the given block. Returning nil without
    # calling the given block will cause the worker to immediately retry locking a job-
    # yielding with nil means there were no jobs to lock, and the worker will pause before
    # retrying.
    def with_locked_job
      reset_cursor if cursor_expired?

      job = lock_job

      # Becuase we were using a cursor when we tried to lock this job, if we fail to find
      # a job it is not necessarily the case that there aren't jobs in the queue. We may
      # have been excluding candidate jobs due to the cursor that are now due to be
      # worked.
      #
      # We should attempt to lock again after resetting our cursor to make sure we include
      # jobs that were excluded in the first attempt.
      if job.nil? && @cursor != 0
        reset_cursor
        job = lock_job
      end

      # Check that the job hasn't just been worked by another worker (it's possible to
      # lock a job that's just been destroyed because pg locks don't obey MVCC). If it has
      # been worked, return nil to immediately retry locking.
      #
      # This can happen with jobs that are already being worked when we begin our lock
      # query. The job row exists but is locked at the point that we materialise our job
      # rows for use in the recursive query. At some point after that, but before we
      # attempt to take our lock, the original worker destroys the job row and unlocks the
      # advisory lock. We then attempt to lock the ID, and succeed, despite the job having
      # already been worked.
      #
      # To avoid working the job a second time, we check whether it exists again after
      # acquiring the lock on it.
      return if job && !exists?(job)

      @cursor = job[:job_id] if job

      yield job
    ensure
      if job
        observe(UnlockTotal, UnlockSecondsTotal) do
          Que.execute("SELECT pg_advisory_unlock($1)", [job[:job_id]])
        end
      end
    end

    private

    def lock_job
      observe(AcquireTotal, AcquireSecondsTotal) do
        Que.execute(:lock_job, [@queue, @cursor]).first
      end
    end

    def exists?(job)
      observe(ExistsTotal, ExistsSecondsTotal) do
        Que.execute(:check_job, job.values_at(*Job::JOB_INSTANCE_FIELDS)).any? if job
      end
    end

    def cursor_expired?
      @cursor_expires_at < monotonic_now
    end

    def reset_cursor
      @cursor = 0
      @cursor_expires_at = monotonic_now + @cursor_expiry
    end

    def observe(metric, metric_duration, &block)
      now = monotonic_now
      block.call
    ensure
      metric.increment({queue: @queue}, 1)
      metric_duration.increment({queue: @queue}, monotonic_now - now)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
