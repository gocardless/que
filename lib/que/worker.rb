# frozen_string_literal: true

require "benchmark"
require "que/metrics"
require "que/locker"

module Que
  class Worker
    DEFAULT_QUEUE = ''
    DEFAULT_WAKE_INTERVAL = 5
    DEFAULT_LOCK_CURSOR_EXPIRY = 0 # seconds

    def initialize(
      queue: DEFAULT_QUEUE,
      wake_interval: DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: DEFAULT_LOCK_CURSOR_EXPIRY,
      metrics_labels: {},
      priority_threshold: 0
    )
      @queue = queue
      @wake_interval = wake_interval
      @metrics = Metrics.new(labels: metrics_labels)
      @locker = Locker.new(queue: queue, cursor_expiry: lock_cursor_expiry, metrics: metrics)
      @locker_default = Locker.new(
        queue: "", cursor_expiry: lock_cursor_expiry, metrics: metrics,
        priority_threshold: priority_threshold,
      )
      @stop = false
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
          *job.values_at(*Job::JOB_INSTANCE_FIELDS)
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
      @locker.with_locked_job do |job_specific|
        @locker_default.with_locked_job do |job_default|
          # We've selected two candidate jobs, one from the default queue and the other
          # from our specified queue. Now we order them by priority, and get rid of the
          # less important job.
          job, unlock_me = [job_specific, job_default].
            sort_by { |j| j&.fetch("priority") || Float::INFINITY }

          # Unlock the one we don't want immediately, regardless of SQL warnings.
          Que.execute "SELECT pg_advisory_unlock($1)", [unlock_me[:job_id]] if unlock_me

          yield job
        end
      end

    end

    def class_for(string)
      Que.constantize(string)
    end
  end
end
