# frozen_string_literal: true

require "pg"
require "benchmark"
require "prometheus/client"

require_relative "locker"
require_relative "job_timeout_error"

module Que
  class Worker
    # Defines the time a worker will wait before checking Postgres for its next job
    DEFAULT_QUEUE = "default"
    DEFAULT_WAKE_INTERVAL = 5.0 # seconds

    METRICS = [
      RunningSecondsTotal = Prometheus::Client::Counter.new(
        :que_worker_running_seconds_total,
        docstring: "Time since starting to work jobs",
        labels: %i[queue worker],
      ),
      SleepingSecondsTotal = Prometheus::Client::Counter.new(
        :que_worker_sleeping_seconds_total,
        docstring: "Time spent sleeping due to no jobs",
        labels: %i[queue worker],
      ),
      JobWorkedTotal = Prometheus::Client::Counter.new(
        :que_job_worked_total,
        docstring: "Counter for all jobs processed",
        labels: %i[job_class priority queue],
      ),
      JobErrorTotal = Prometheus::Client::Counter.new(
        :que_job_error_total,
        docstring: "Counter for all jobs that were run but errored",
        labels: %i[job_class priority queue],
      ),
      JobWorkedSecondsTotal = Prometheus::Client::Counter.new(
        :que_job_worked_seconds_total,
        docstring: "Sum of the time spent processing each job class",
        labels: %i[job_class priority queue worker],
      ),
      JobLatencySecondsTotal = Prometheus::Client::Counter.new(
        :que_job_latency_seconds_total,
        docstring: "Sum of time spent waiting in queue",
        labels: %i[job_class priority queue],
      ),
    ].freeze

    # We have metrics of the form "worker running seconds total", where we need to be
    # updating the metrics over the course of a very long-running task. This class is used
    # to track on-going 'traces', which are records of tasks starting and stopping, and is
    # used to periodically update the associated trace metrics.
    #
    # Each worker exposes a X method that can be used to trigger an update of these
    # metrics. This in turn is used by the Middleware::WorkerCollector to ensure our
    # worker metrics are correct before serving prometheus metrics.
    class LongRunningMetricTracer
      Trace = Struct.new(:metric, :labels, :time)

      def initialize(worker)
        @worker = worker
        @lock = Mutex.new
        @traces = []
      end

      # Update currently traced metrics- this will increment all on-going traces with the
      # delta of time between the last update and now.
      def collect(traces = @traces)
        # If our worker has violently died, and didn't clean-up its traces, we don't want
        # to continue incrementing our metrics as this would imply we are still running
        # and alive.
        return if @worker.stopped?

        @lock.synchronize do
          now = monotonic_now
          traces.each do |trace|
            time_since = [now - trace.time, 0].max
            trace.time = now
            trace.metric.increment(
              by: time_since,
              labels: trace.labels.merge(worker: @worker.object_id),
            )
          end
        end
      end

      def trace(metric, labels = {})
        start(metric, labels)
        yield
      ensure
        stop(metric, labels)
      end

      private

      def start(metric, labels = {})
        @lock.synchronize { @traces << Trace.new(metric, labels, monotonic_now) }
      end

      def stop(metric, labels = {})
        matching = nil
        @lock.synchronize do
          matching, @traces = @traces.partition do |trace|
            trace.metric == metric && trace.labels == labels
          end
        end

        collect(matching)
      end

      # We're doing duration arithmetic which should make use of monotonic clocks, to
      # avoid changes to the system time from affecting our metrics.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def initialize(
      queue: DEFAULT_QUEUE,
      wake_interval: DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: DEFAULT_WAKE_INTERVAL,
      lock_window: nil,
      lock_budget: nil
    )
      @queue = queue
      @wake_interval = wake_interval
      @tracer = LongRunningMetricTracer.new(self)
      @stop = false # instruct worker to stop
      @stopped = false # mark worker as having stopped
      @current_running_job = nil
      @locker = Locker.new(
        queue: queue,
        cursor_expiry: lock_cursor_expiry,
        window: lock_window,
        budget: lock_budget,
      )
    end

    attr_reader :metrics

    def work_loop
      return if @stop

      @tracer.trace(RunningSecondsTotal, queue: @queue) do
        loop do
          case event = work
          when :job_not_found, :postgres_error
            Que.logger&.info(event: "que.#{event}", wake_interval: @wake_interval)
            @tracer.trace(SleepingSecondsTotal, queue: @queue) { sleep(@wake_interval) }
          when :job_worked
            nil # immediately find a new job to work
          end

          break if @stop
        end
      end
    ensure
      @stopped = true
    end

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    def work
      Que.adapter.checkout do
        @locker.with_locked_job do |job|
          return :job_not_found if job.nil?

          klass = class_for(job[:job_class])

          log_keys = {
            priority: job["priority"],
            queue: job["queue"],
            handler: job["job_class"],
            job_class: job["job_class"],
            job_error_count: job["error_count"],
            que_job_id: job["job_id"],
            **(klass.log_context_proc&.call(job) || {}),
          }

          labels = {
            job_class: job["job_class"], priority: job["priority"], queue: job["queue"]
          }

          begin
            Que.logger&.info(
              log_keys.merge(
                event: "que_job.job_begin",
                msg: "Job acquired, beginning work",
                latency: job["latency"],
              )
            )

            # Note the time spent waiting in the queue before being processed, and update
            # the jobs worked count here so that latency_seconds_total / worked_total
            # doesn't suffer from skew.
            JobLatencySecondsTotal.increment(by: job[:latency], labels: labels)
            JobWorkedTotal.increment(labels: labels)

            duration = Benchmark.measure do
              # TODO: _run -> run_and_destroy(*job[:args])
              @tracer.trace(JobWorkedSecondsTotal, labels) do
                klass.new(job).tap do |inst|
                  @current_running_job = inst
                  begin
                    inst._run
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
              )
            )
          rescue StandardError, NotImplementedError, JobTimeoutError => error
            JobErrorTotal.increment(labels: labels)
            Que.logger&.error(
              log_keys.merge(
                event: "que_job.job_error",
                msg: "Job failed with error",
                error: error.inspect,
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
    rescue PG::Error, Adapters::UnavailableConnection => _error
      # In the event that our Postgres connection is bad, we don't want that error to halt
      # the work loop. Instead, we should let the work loop sleep and retry.
      :postgres_error
    end
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/AbcSize

    def stop!
      @stop = true
      @current_running_job&.stop!
    end

    def stopped?
      @stopped
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
          count**4 + 3, # exponentially back off when retrying failures
          "#{error.message}\n#{error.backtrace.join("\n")}",
          *job.values_at(*Job::JOB_INSTANCE_FIELDS),
        ]
      )
    end

    def class_for(string)
      Que.constantize(string)
    end
  end
end
