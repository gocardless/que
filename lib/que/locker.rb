# frozen_string_literal: true

require "prometheus/client"
require_relative "leaky_bucket"

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
        :que_locker_exists_total,
        docstring: "Counter of attempts to check job existence before locking",
        labels: [:queue],
      ),
      ExistsSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_exists_seconds_total,
        docstring: "Seconds spent checking job exists before locking",
        labels: [:queue],
      ),
      UnlockTotal = Prometheus::Client::Counter.new(
        :que_locker_unlock_total,
        docstring: "Counter of attempts to unlock job advisory locks",
        labels: [:queue],
      ),
      UnlockSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_unlock_seconds_total,
        docstring: "Seconds spent unlocking job advisory locks",
        labels: [:queue],
      ),
      ThrottleSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_throttle_seconds_total,
        docstring: "Seconds spent throttling calls to lock jobs",
        labels: [:queue],
      ),
      AcquireTotal = Prometheus::Client::Counter.new(
        :que_locker_acquire_total,
        docstring: "Counter of number of job lock queries executed",
        labels: %i[queue strategy],
      ),
      AcquireSecondsTotal = Prometheus::Client::Counter.new(
        :que_locker_acquire_seconds_total,
        docstring: "Seconds spent running job lock query",
        labels: %i[queue strategy],
      ),
    ].freeze

    def initialize(queue:, cursor_expiry:, window: nil, budget: nil, secondary_queues: [])
      @queue = queue
      @cursor_expiry = cursor_expiry
      @queue_cursors = {}
      @queue_expires_at = {}
      @secondary_queues = secondary_queues
      @consolidated_queues = Array.wrap(queue).concat(secondary_queues)

      # Create a bucket that has 100% capacity, so even when we don't apply a limit we
      # have a valid bucket that we can use everywhere
      @leaky_bucket = LeakyBucket.new(window: window || 1.0, budget: budget || 1.0)

      # Initialise the cursor maps
      handle_expired_cursors!
    end

    # Acquire a job for the period of running the given block. Returning nil without
    # calling the given block will cause the worker to immediately retry locking a job-
    # yielding with nil means there were no jobs to lock, and the worker will pause before
    # retrying.
    def with_locked_job
      handle_expired_cursors!

      job = @consolidated_queues.lazy.filter_map do |queue|
        cursor = @queue_cursors.fetch(queue, 0)
        found_job = lock_job_in(queue, cursor)

        # Because we were using a cursor when we tried to lock this job, if we fail to
        # find a job it is not necessarily the case that there aren't jobs in the
        # queue. We may have been excluding candidate jobs due to the cursor that
        # are now due to be worked.
        #
        # We should attempt to lock again after resetting our cursor to make sure we
        # include jobs that were excluded in the first attempt.
        #
        # We leave the cursors for subsequant queues alone however. The idea there is
        # that if we've touched a subsequant queue at some point and gotten on a cursor
        # then work appears on a more pressing queue then `handle_expired_cursors` will
        # do the appropriate book keeping.
        if found_job.nil? && cursor != 0
          reset_cursor_for!(queue)
          found_job = lock_job_in(queue, 0)
        end

        found_job
      end.first

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

      @queue_cursors[job[:queue]] = job[:job_id] if job

      yield job
    ensure
      if job
        observe(UnlockTotal, UnlockSecondsTotal) do
          Que.execute("SELECT pg_advisory_unlock($1)", [job[:job_id]])
        end
      end
    end

    private

    def lock_job_in(queue, cursor)
      observe(nil, ThrottleSecondsTotal) { @leaky_bucket.refill }
      @leaky_bucket.observe { execute_lock_job_in(queue, cursor) }
    end

    def execute_lock_job_in(queue, cursor)
      strategy = cursor.zero? ? "full" : "cursor"
      observe(AcquireTotal, AcquireSecondsTotal, strategy: strategy) do
        lock_job_query(queue, cursor)
      end
    end

    def exists?(job)
      observe(ExistsTotal, ExistsSecondsTotal) do
        Que.execute(:check_job, job.values_at(*Job::JOB_INSTANCE_FIELDS)).any? if job
      end
    end

    def lock_job_query(queue, cursor)
      Que.execute(:lock_job, [queue, cursor]).first
    end

    def handle_expired_cursors!
      @consolidated_queues.each do |queue|
        queue_cursor_expires_at = @queue_expires_at.fetch(queue, monotonic_now)
        reset_cursor_for!(queue) if queue_cursor_expires_at < monotonic_now
      end
    end

    def reset_cursor_for!(queue)
      @queue_cursors[queue] = 0
      @queue_expires_at[queue] = monotonic_now + @cursor_expiry
    end

    def observe(metric, metric_duration, labels = {})
      now = monotonic_now
      yield
    ensure
      metric&.increment(labels: labels.merge(queue: @queue))
      metric_duration&.increment(
        by: monotonic_now - now,
        labels: labels.merge(queue: @queue),
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
