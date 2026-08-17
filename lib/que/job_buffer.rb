# frozen_string_literal: true

module Que
  # A bounded, thread-safe queue of already-locked jobs, shared between a single process's
  # Locker (the producer, which polls Postgres and pushes locked jobs in) and its pool of
  # Workers (the consumers, which block on #shift until a job is available).
  #
  # Centralising job acquisition behind this buffer means only the Locker ever queries
  # Postgres to lock jobs - worker threads never do, so a process with N worker threads
  # makes one lock query per poll cycle instead of N.
  class JobBuffer
    def initialize(maximum_size:)
      @maximum_size = maximum_size
      @array = []

      # Every job_id currently locked by this process and not yet released - both jobs
      # still sitting in @array, and ones already shifted out to a worker that's actively
      # processing them. The Locker excludes these from every lock query (see Locker
      # #poll), because pg_try_advisory_lock is reentrant *within the same session*: if we
      # didn't exclude them, a poll could re-lock (and re-dispatch) a job we already hold,
      # since our own session is always able to "acquire" a lock it already has.
      @held_ids = Set.new

      @stopping = false
      @mutex = Mutex.new
      @job_available = ConditionVariable.new
      @space_available = ConditionVariable.new
    end

    attr_reader :maximum_size

    # Push newly-locked jobs onto the buffer, sorted so that higher-priority (and then
    # earlier-run_at) jobs are shifted first. Returns any jobs that didn't fit, so the
    # caller (the Locker) can unlock them again rather than leave them buffered forever.
    def push(*jobs)
      sync do
        return jobs if @stopping

        space = _available_capacity
        accepted = jobs.first(space)
        rejected = jobs.drop(accepted.size)

        unless accepted.empty?
          @array.concat(accepted)
          @array.sort_by! { |job| [job[:priority], job[:run_at], job[:job_id]] }
          accepted.each { |job| @held_ids << job[:job_id] }
          @job_available.broadcast
        end

        rejected
      end
    end

    # Blocks until a job is available or the buffer is stopped (in which case it returns
    # false).
    def shift
      sync do
        loop do
          return false if @stopping

          unless @array.empty?
            job = @array.shift
            @space_available.broadcast
            return job
          end

          @job_available.wait(@mutex)
        end
      end
    end

    # Blocks (up to `timeout` seconds) until there's free capacity in the buffer, or the
    # buffer is stopped. Used by the Locker to back off when its last poll filled the
    # buffer completely, while waking promptly whenever a worker frees up a slot.
    def wait_for_space(timeout)
      sync do
        return if @stopping || _available_capacity.positive?

        @space_available.wait(@mutex, timeout)
      end
    end

    # Blocks up to `timeout` seconds, or until the buffer is stopped - unlike
    # #wait_for_space, this always waits the full timeout even when space is already
    # available. Used by the Locker when its last poll *didn't* fill the buffer (e.g. the
    # queue's empty, or every attempt is failing), so it backs off for a full cycle
    # instead of busy-looping against Postgres as fast as the CPU allows.
    def wait_for_stop(timeout)
      sync do
        return if @stopping

        @space_available.wait(@mutex, timeout)
      end
    end

    # Called by a Worker once it's done with a job (whether it succeeded, failed, or the
    # unlock itself errored) - marks the job_id as no longer held, so a future poll is free
    # to consider it again.
    def release(job_id)
      sync { @held_ids.delete(job_id) }
    end

    # A snapshot of every job_id currently held (buffered or checked out to a worker),
    # for the Locker to exclude from its next lock query.
    def held_ids
      sync { @held_ids.to_a }
    end

    def available_capacity
      sync { _available_capacity }
    end

    def size
      sync { @array.size }
    end

    def stop
      sync do
        @stopping = true
        @job_available.broadcast
        @space_available.broadcast
      end
    end

    def stopping?
      sync { @stopping }
    end

    # Drains and returns all buffered (but not yet claimed) jobs, so the caller can unlock
    # them. Used during graceful shutdown, so we never leave an advisory lock held on a job
    # that's sitting unclaimed in the buffer.
    def clear
      sync do
        jobs = @array
        @array = []
        jobs.each { |job| @held_ids.delete(job[:job_id]) }
        jobs
      end
    end

    private

    def _available_capacity
      maximum_size - @array.size
    end

    def sync(&block)
      @mutex.synchronize(&block)
    end
  end
end
