# frozen_string_literal: true

require "prometheus/client"
require_relative "leaky_bucket"
require_relative "locker"

module Que
  # The CentralizedLocker runs a single background thread per process that polls
  # Postgres for jobs, locks them, and pushes them into a shared JobBuffer for worker
  # threads (CentralizedWorker) to consume.
  #
  # This backs `architecture: :centralized` on WorkerGroup - see the README for context
  # on why it exists (fixing lock contention that scales with worker count) and how to
  # opt into it. The original per-worker-thread Locker remains the default
  # (`architecture: :legacy`) and is unaffected by this class.
  #
  # Centralising locking behind one Locker per process (rather than one per worker
  # thread) means a process with N worker threads makes one batched lock query per poll
  # cycle, instead of N independent single-job lock queries competing with each other.
  #
  # For performance, the locker keeps track of the last job ID it locked per queue, and
  # uses that job's ID to begin the next attempt to acquire jobs. There is a point where
  # the performance of lock acquisition goes off a cliff, and using the previous job's ID
  # delays the point at which that occurs.
  #
  # For more information, see the 'Predicate Specificity' chapter of:
  # https://brandur.org/postgres-queues
  class CentralizedLocker
    RUN_AT_CURSOR_RESET = Locker::RUN_AT_CURSOR_RESET

    DEFAULT_WAKE_INTERVAL = 5.0 # seconds

    METRICS = [
      # This is the only metric unique to CentralizedLocker - everything else below
      # reuses Locker's existing Prometheus constants (rather than declaring duplicates
      # with the same metric names), since only one architecture is ever active in a
      # given process and operators shouldn't need separate dashboards depending on
      # which is selected.
      JobsLockedTotal = Prometheus::Client::Counter.new(
        :que_locker_jobs_locked_total,
        docstring: "Counter of jobs locked and pushed into the job buffer",
        labels: %i[queue primary_queue worked_queue],
      ),
    ].freeze

    def initialize(
      queue:,
      cursor_expiry:,
      job_buffer:,
      window: nil,
      budget: nil,
      secondary_queues: [],
      run_at_cursor: false,
      wake_interval: DEFAULT_WAKE_INTERVAL
    )
      @queue = queue
      @cursor_expiry = cursor_expiry
      @run_at_cursor = run_at_cursor
      @job_buffer = job_buffer
      @wake_interval = wake_interval
      @queue_cursors = {}
      @run_at_lower_bounds = {}
      @queue_expires_at = {}
      @secondary_queues = secondary_queues
      @consolidated_queues = Array.wrap(queue).concat(secondary_queues)

      # Create a bucket that has 100% capacity, so even when we don't apply a limit we
      # have a valid bucket that we can use everywhere
      @leaky_bucket = LeakyBucket.new(window: window || 1.0, budget: budget || 1.0)

      @stop = false
      @last_poll_result = nil

      # Initialise the cursor maps
      handle_expired_cursors!
    end

    attr_reader :thread

    # Starts the background thread that polls for jobs. Returns self.
    def start
      @thread = Thread.new { poll_loop }
      self
    end

    # Ask the poll loop to stop after its current cycle. Does not block - use
    # wait_until_stopped to wait for the thread to actually exit (and for buffered jobs to
    # be unlocked).
    def stop!
      @stop = true
    end

    def wait_until_stopped
      @thread&.join
    end

    def alive?
      !!@thread&.alive?
    end

    def healthy?
      @last_poll_result != :postgres_error
    end

    private

    def poll_loop
      until @stop
        poll
        break if @stop

        # If the buffer's still got room after that poll, we didn't find enough work to
        # fill it (the queue's quiet, or every attempt is failing) - back off for a full
        # wake_interval rather than busy-looping against Postgres. Only wait specifically
        # for a freed-up slot when we filled the buffer completely, since then there's
        # reason to think more work is waiting right behind it.
        if @job_buffer.available_capacity.positive?
          @job_buffer.wait_for_stop(@wake_interval)
        else
          @job_buffer.wait_for_space(@wake_interval)
        end
      end
    ensure
      # Drain whatever's left in the buffer (jobs we locked but no worker had claimed yet)
      # so we don't leave advisory locks held on jobs nobody is going to work.
      unlock_jobs(@job_buffer.clear)
    end

    # Runs a single poll cycle: for each consolidated queue (primary, then secondaries), in
    # order, lock as many due jobs as there's free space in the job buffer for, and push
    # them in. Updates @last_poll_result (used by #healthy?) as a side effect, so that
    # calling #poll directly (e.g. in tests) reflects health correctly too.
    def poll
      handle_expired_cursors!

      @consolidated_queues.each do |queue|
        space = @job_buffer.available_capacity
        break if space <= 0

        jobs = lock_jobs_for(queue, space)
        next if jobs.empty?

        # jobs is ordered by (priority, run_at, job_id) - see the ORDER BY in
        # lock_jobs_batch - so the last entry is the furthest we've progressed through
        # the queue in that order.
        last = jobs.last
        @queue_cursors[queue] = last[:job_id]
        @run_at_lower_bounds[queue] = last[:run_at] if @run_at_cursor

        rejected = @job_buffer.push(*jobs)
        unlock_jobs(rejected) if rejected.any?
      end

      @last_poll_result = :ok
    rescue PG::Error, Adapters::UnavailableConnection
      @last_poll_result = :postgres_error
    end

    # Locks up to `limit` jobs from `queue`. If the current cursor turns up nothing, retry
    # once from the start of the queue - it's not necessarily the case that there aren't
    # jobs in the queue, we may have been excluding candidates due to the cursor that are
    # now due to be worked. We leave cursors for other queues alone; if a later poll of
    # this queue starts finding jobs again, handle_expired_cursors! will eventually reset
    # it based on the expiry rather than this immediate retry.
    def lock_jobs_for(queue, limit)
      cursor = @queue_cursors.fetch(queue, 0)
      run_at_lower_bound = @run_at_lower_bounds.fetch(queue, RUN_AT_CURSOR_RESET)

      jobs = lock_jobs_in(queue, cursor, run_at_lower_bound, limit)

      if jobs.empty? && cursor != 0
        reset_cursor_for!(queue)
        jobs = lock_jobs_in(queue, 0, RUN_AT_CURSOR_RESET, limit)
      end

      jobs
    end

    def lock_jobs_in(queue, cursor, run_at_lower_bound, limit)
      observe(nil, Locker::ThrottleSecondsTotal, worked_queue: queue) { @leaky_bucket.refill }
      jobs = @leaky_bucket.observe { execute_lock_jobs_in(queue, cursor, run_at_lower_bound, limit) }

      verify_existence(queue, jobs)
    end

    def execute_lock_jobs_in(queue, cursor, run_at_lower_bound, limit)
      strategy = cursor.zero? ? "full" : "cursor"
      # Que.execute JSON-encodes Array params (see Adapters::Base#execute), which isn't
      # valid input for a native Postgres array - build the `{1,2,3}` literal ourselves.
      held_ids = "{#{@job_buffer.held_ids.join(',')}}"

      observe(Locker::AcquireTotal, Locker::AcquireSecondsTotal,
              worked_queue: queue,
              strategy: strategy) do
        Que.execute(:lock_jobs_batch, [queue, cursor, run_at_lower_bound, limit, held_ids])
      end
    end

    # Check that jobs we just locked haven't just been worked and destroyed by another
    # locker (it's possible to lock a job that's just been destroyed because pg locks
    # don't obey MVCC). This can happen with jobs that are already being worked when we
    # begin our lock query: the job row exists but is locked at the point that we
    # materialise our job rows for use in the recursive query. At some point after that,
    # but before we attempt to take our lock, the original worker destroys the job row and
    # unlocks the advisory lock. We then attempt to lock the ID, and succeed, despite the
    # job having already been worked.
    #
    # Any jobs that didn't survive this check are unlocked immediately and excluded from
    # what gets pushed into the buffer, so we never hand a worker a job that's already
    # been completed.
    def verify_existence(queue, jobs)
      return jobs if jobs.empty?

      # Que.execute JSON-encodes Array params (see Adapters::Base#execute), which isn't
      # valid input for a native Postgres array - build the `{1,2,3}` literal ourselves so
      # it's passed through as a plain string and `$1::bigint[]` can cast it directly.
      id_array_literal = "{#{jobs.map { |job| job[:job_id] }.join(',')}}"

      surviving_ids = observe(Locker::ExistsTotal, Locker::ExistsSecondsTotal, worked_queue: queue) do
        Que.execute(:check_jobs_batch, [id_array_literal]).map { |row| row[:job_id] }
      end.to_set

      destroyed, survived = jobs.partition { |job| !surviving_ids.include?(job[:job_id]) }
      unlock_jobs(destroyed) if destroyed.any?

      JobsLockedTotal.increment(by: survived.size,
                                labels: { worked_queue: queue, queue: @queue,
                                          primary_queue: @queue })

      survived
    end

    def unlock_jobs(jobs)
      jobs.each do |job|
        observe(Locker::UnlockTotal, Locker::UnlockSecondsTotal, worked_queue: job[:queue]) do
          Que.execute(:unlock_job, [job[:job_id]])
        end
      end
    end

    def handle_expired_cursors!
      @consolidated_queues.each do |queue|
        queue_cursor_expires_at = @queue_expires_at.fetch(queue, monotonic_now)
        reset_cursor_for!(queue) if queue_cursor_expires_at < monotonic_now
      end
    end

    def reset_cursor_for!(queue)
      @queue_cursors[queue] = 0
      @run_at_lower_bounds[queue] = RUN_AT_CURSOR_RESET
      @queue_expires_at[queue] = monotonic_now + @cursor_expiry
    end

    def observe(metric, metric_duration, labels = {})
      now = monotonic_now
      yield
    ensure
      metric&.increment(labels: labels.merge(queue: @queue, primary_queue: @queue))
      metric_duration&.increment(
        by: monotonic_now - now,
        labels: labels.merge(queue: @queue, primary_queue: @queue),
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
