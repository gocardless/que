# frozen_string_literal: true

require "pg"
require "benchmark"

require_relative "legacy_locker"
require_relative "job_timeout_error"
require_relative "worker"

module Que
  # The pre-centralization Worker: owns its own LegacyLocker and independently locks and
  # works exactly one job at a time on its own thread.
  #
  # This is kept only to support `--architecture=legacy` (see WorkerGroup), as a rollback
  # path while the centralized Locker+JobBuffer architecture (see Worker) bakes in
  # production. Once centralized locking is the sole path, this class (along with
  # LegacyLocker and the architecture switch) should be removed.
  #
  # Deliberately reuses Worker's Prometheus metric constants and LongRunningMetricTracer
  # rather than declaring its own copies - only one architecture is ever active in a given
  # process, and operators shouldn't need separate dashboards depending on which is
  # selected.
  class LegacyWorker
    def initialize(
      queue: Worker::DEFAULT_QUEUE,
      wake_interval: Worker::DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: Worker::DEFAULT_WAKE_INTERVAL,
      lock_window: nil,
      lock_budget: nil,
      secondary_queues: [],
      run_at_cursor: false
    )
      @queue = queue
      @wake_interval = wake_interval
      @tracer = Worker::LongRunningMetricTracer.new(self)
      @stop = false # instruct worker to stop
      @stopped = false # mark worker as having stopped
      @current_running_job = nil
      @last_work_result = nil
      @locker = LegacyLocker.new(
        queue: queue,
        cursor_expiry: lock_cursor_expiry,
        window: lock_window,
        budget: lock_budget,
        secondary_queues: secondary_queues,
        run_at_cursor: run_at_cursor,
      )
    end

    attr_reader :metrics

    def work_loop
      return if @stop

      @tracer.trace(Worker::RunningSecondsTotal, queue: @queue, primary_queue: @queue) do
        loop do
          case work
          when :postgres_error
            Que.logger&.info(event: "que.postgres_error", wake_interval: @wake_interval)
            @tracer.trace(Worker::SleepingSecondsTotal, queue: @queue, primary_queue: @queue) do
              sleep(@wake_interval)
            end
          when :job_not_found
            Que.logger&.debug(event: "que.job_not_found", wake_interval: @wake_interval)
            @tracer.trace(Worker::SleepingSecondsTotal, queue: @queue, primary_queue: @queue) do
              sleep(@wake_interval)
            end
          when :job_worked
            nil # immediately find a new job to work
          end

          break if @stop
        end
      end
    ensure
      @stopped = true
    end

    def work
      Que.adapter.checkout do
        @locker.with_locked_job do |job|
          return (@last_work_result = :job_not_found) if job.nil?

          log_keys = {
            priority: job["priority"],
            # TODO alerting / monitoring pre addition of secondary queues
            # assume that a worker would not work a job from another queue.
            # With the addition of secondary queues this is no longer true.
            # To support moving to the new `primary_queue` field without
            # disrupting existing tooling we "lie" and say the queue worked
            # is the primary queue. Longer term alerting / monitoring should move
            # to look at `primary_queue` and `worked_queue` instead.
            queue: @queue,
            primary_queue: @queue,
            worked_queue: job["queue"],
            handler: job["job_class"],
            job_class: actual_job_class_name(job["job_class"], job["args"]),
            job_error_count: job["error_count"],
            que_job_id: job["job_id"],
          }

          labels = {
            job_class: actual_job_class_name(job["job_class"], job["args"]),
            priority: job["priority"],
            queue: @queue,
            primary_queue: @queue,
            worked_queue: job["queue"],
          }

          begin
            klass = class_for(job[:job_class])

            log_keys.merge!(
              (klass.log_context_proc&.call(job) || {}),
            )

            Que.logger&.info(
              log_keys.merge(
                event: "que_job.job_begin",
                msg: "Job acquired, beginning work",
                latency: job["latency"],
              ),
            )

            # Note the time spent waiting in the queue before being processed, and update
            # the jobs worked count here so that latency_seconds_total / worked_total
            # doesn't suffer from skew.
            Worker::JobLatencySecondsTotal.increment(by: job[:latency], labels: labels)
            Worker::JobWorkedTotal.increment(labels: labels)

            duration = Benchmark.measure do
              # TODO: _run -> run_and_destroy(*job[:args])
              @tracer.trace(Worker::JobWorkedSecondsTotal, labels) do
                klass.new(job).tap do |job_instance|
                  @current_running_job = job_instance
                  begin
                    job_instance._run
                  ensure
                    @current_running_job = nil
                  end
                end
              end
            end.real

            Que.logger&.info(
              log_keys.merge(
                event: "que_job.job_worked",
                msg: "Successfully worked job",
                duration: duration,
              ),
            )
          rescue StandardError, NotImplementedError, JobTimeoutError => e
            Worker::JobErrorTotal.increment(labels: labels)
            Que.logger&.error(
              log_keys.merge(
                event: "que_job.job_error",
                msg: "Job failed with error",
                error: e.inspect,
              ),
            )

            # For compatibility with que-failure, we need to allow failure handlers to be
            # defined on the job class.
            if klass.respond_to?(:handle_job_failure)
              klass.handle_job_failure(e, job)
            else
              handle_job_failure(e, job)
            end
          end
          @last_work_result = :job_worked
        end
      end
    rescue PG::Error, Adapters::UnavailableConnection => _e
      # In the event that our Postgres connection is bad, we don't want that error to halt
      # the work loop. Instead, we should let the work loop sleep and retry.
      @last_work_result = :postgres_error
    end

    def stop!
      @stop = true
      @current_running_job&.stop!
    end

    def stopped?
      @stopped
    end

    def healthy?
      @last_work_result != :postgres_error
    end

    def collect_metrics
      @tracer.collect
    end

    private

    # Set the error and retry with back-off
    def handle_job_failure(error, job)
      count = job[:error_count].to_i + 1

      Que.execute(
        :set_error, [
          count,
          (count**4) + 3, # exponentially back off when retrying failures
          "#{error.message}\n#{error.backtrace.join("\n")}",
          *job.values_at(*Job::JOB_INSTANCE_FIELDS),
        ]
      )
    end

    def class_for(string)
      Que.constantize(string)
    end

    def actual_job_class_name(class_name, args)
      return args.first["job_class"] if class_name.include?("ActiveJob::QueueAdapters")

      class_name
    end
  end
end
