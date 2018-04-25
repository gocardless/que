# frozen_string_literal: true

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
    def initialize(queue:, cursor_expiry:, metrics:, priority_threshold: 0)
      @queue = queue
      @metrics = metrics
      @priority_threshold = priority_threshold
      @cursor_expiry = cursor_expiry
      @cursor = 0
      @cursor_expires_at = monotonic_now
    end

    # Acquire a job for the period of running the given block.
    def with_locked_job
      reset_cursor if cursor_expired?

      # Check that the job hasn't just been worked by another worker (it's possible to
      # lock a job that's just been destroyed because pg locks don't obey MVCC). If it has
      # been worked, act as if we've worked it.
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
      job = lock_job
      reset_cursor unless job # if no job was found, we should reset the cursor
      job = nil unless exists?(job)

      @cursor = job[:job_id] if job

      yield job
    ensure
      Que.execute("SELECT pg_advisory_unlock($1)", [job[:job_id]]) if job
    end

    private

    def lock_job
      @metrics.trace_acquire_job(queue: @queue) do
        Que.execute(:lock_job, [@queue, @cursor, @priority_threshold]).first
      end
    end

    def cursor_expired?
      @cursor_expires_at < monotonic_now
    end

    def reset_cursor
      @cursor = 0
      @cursor_expires_at = monotonic_now + @cursor_expiry
    end

    def exists?(job)
      Que.execute(:check_job, job.values_at(*Job::JOB_INSTANCE_FIELDS)).any? if job
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
