# frozen_string_literal: true

require "benchmark"
require "que/metrics"

module Que
  class Worker
    # Defines the time a worker will wait before checking Postgres for its next job
    WAKE_INTERVAL = 5
    DEFAULT_QUEUE = ''
    JOB_INSTANCE_FIELDS = %i[queue priority run_at job_id].freeze

    def initialize(queue: DEFAULT_QUEUE, wake_interval: WAKE_INTERVAL, metrics_labels: {}, priority_threshold: 0)
      @queue  = queue
      @wake_interval = wake_interval
      @stop = false
      @metrics = Metrics.new(labels: metrics_labels)

      # Supported in a custom GC branch that will never be merged.
      @priority_threshold = priority_threshold
    end

    attr_reader :metrics

    def work_loop
      return if @stop
      stop_trace = @metrics.trace_start_work(queue: @queue)

      loop do
        case work
        when :job_not_found, :error then sleep(@wake_interval)
        when :job_worked then nil # immediately find a new job to work
        end

        break if @stop
      end
    ensure
      stop_trace.call if stop_trace
    end

    def work
      Que.adapter.checkout do
        with_locked_job do |job|
          return :job_not_found if job.nil?

          # Check that the job hasn't just been worked by another worker (it's possible to
          # lock a job that's just been destroyed because pg locks don't obey MVCC). If it
          # has been worked, act as if we've worked it.
          #
          # In explanation, what happens to cause this is a job is already being processed
          # when we begin our lock query. This means the job row exists but is locked when
          # we have materialized our job rows for use in the recursive query. At some
          # point after this, but before we attempt to take our lock, the original worker
          # destroys the job row and unlocks the advisory lock. We then attempt to lock
          # this ID, and succeed, despite the job having already been worked.
          return :job_worked unless job_exists?(job)

          log_keys = {
            id: job["job_id"],
            priority: job["priority"],
            queue: job["queue"],
            job_class: job["job_class"],
            job_error_count: job["error_count"],
          }

          begin
            Que.logger&.info(
              log_keys.merge(
                event: "job_begin",
                msg: "Job acquired, beginning work",
              )
            )

            klass = class_for(job[:job_class])
            # TODO: _run -> run_and_destroy(*job[:args])
            duration = Benchmark.measure do
              @metrics.trace_work_job(job) { klass.new(job)._run }
            end.real

            Que.logger&.info(
              log_keys.merge(
                event: "job_worked",
                msg: "Successfully worked job",
                duration: duration,
              )
            )
          rescue => error
            Que.logger&.error(
              log_keys.merge(
                event: "job_error",
                msg: "Job failed with error",
                error: error.to_s,
              )
            )

            # For compatibility with que-failure, we need to allow failure handlers to be
            # defined on the job class.
            if klass.respond_to?(:handle_job_failure)
              klass.handle_job_failure(error, job)
            else
              handle_job_failure(error, job)
            end
          end
          :job_worked
        end
      end
    rescue PG::Error => _error
      # In the event that our Postgres connection is bad, we don't want that error to halt
      # the work loop. Instead, we should let the work loop sleep and retry.
      :error
    end

    def stop!
      @stop = true
    end

    private

    # Set the error and retry with back-off
    def handle_job_failure(error, job)
      count = job[:error_count].to_i + 1

      Que.execute(
        :set_error, [
          count,
          count ** 4 + 3, # exponentially back off when retrying failures
          "#{error.message}\n#{error.backtrace.join("\n")}",
          *job.values_at(*JOB_INSTANCE_FIELDS)
        ]
      )
    end


    # We've introduced priority_threshold at GC to facilitate our transition from
    # Softlayer to GCP. By providing Que with a priority threshold, we can configure
    # workers in GCP to select an adjustable quantity of our job queue, in increasing
    # priority order.
    #
    # We want to attempt locking a job in our specified queue and in the default queue.
    # The job with the highest priority is the one we'll work. This will result in double
    # locking jobs but the performance impact should be negligible.
    def with_locked_job
      # Separate the job acquisition from yielding the job, as we want to track the job
      # runtime separately.
      job_from_queue = acquire_job(@queue, 0)
      job_from_default = acquire_job("", @priority_threshold) unless @queue == ""

      # We've selected two candidate jobs, one from the default queue and the other from
      # our specified queue. Now we order them by priority, and get rid of the less
      # important job.
      job, unlock_me = [job_from_queue, job_from_default].
        sort_by { |j| j&.fetch("priority") || Float::INFINITY }
      Que.execute "SELECT pg_advisory_unlock($1)", [unlock_me[:job_id]] if unlock_me

      yield job
    ensure
      Que.execute("SELECT pg_advisory_unlock($1)", [job[:job_id]]) if job
    end

    def acquire_job(queue, priority_threshold)
      @metrics.trace_acquire_job(queue: queue) do
        Que.execute(:lock_job, [queue, priority_threshold]).first
      end
    end

    def job_exists?(job)
      Que.execute(:check_job, job.values_at(*JOB_INSTANCE_FIELDS)).any?
    end

    def class_for(string)
      Que.constantize(string)
    end
  end
end
