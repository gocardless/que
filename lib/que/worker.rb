# frozen_string_literal: true

require "pg"
require "benchmark"
require "prometheus/client"

require_relative "locker"
require_relative "job_timeout_error"

module Que
  class Worker
    # Defines the time a worker will wait before checking Postgres for its next job
    DEFAULT_QUEUE = ""
    DEFAULT_WAKE_INTERVAL = 5
    DEFAULT_LOCK_CURSOR_EXPIRY = 0 # seconds

    RunningSecondsTotal = Prometheus::Client.registry.counter(
      :que_worker_running_seconds_total, "Time since starting to work jobs",
    )
    SleepingSecondsTotal = Prometheus::Client.registry.counter(
      :que_worker_sleeping_seconds_total, "Time spent sleeping due to no jobs",
    )
    JobsWorkedTotal = Prometheus::Client.registry.counter(
      :que_job_worked_total, "Counter for all jobs processed",
    )
    JobsErrorTotal = Prometheus::Client.registry.counter(
      :que_job_error_total, "Counter for all jobs that were run but errored",
    )
    JobsWorkedSecondsTotal = Prometheus::Client.registry.counter(
      :que_job_worked_seconds_total, "Sum of the time spent processing each job class",
    )
    JobsLatencySecondsTotal = Prometheus::Client.registry.counter(
      :que_job_latency_seconds_total, "Sum of time spent by job and priority waiting in queue",
    )

    # Metrics from the worker are often collected over long spans of time. We don't want
    # to update the metric only once the long-running task has complete, as this leads to
    # graphs that dump all the weight of your task just as it finishes. The Collector
    # class is used to provide an interface to update each metric as we receive requests
    # to read the metric, solving this problem.
    class Collector
      Trace = Struct.new(:metric, :labels, :time)

      def initialize(worker)
        @worker = worker
        @lock = Mutex.new
        @traces = []
      end

      def collect(traces = @traces)
        return if @worker.stopped?

        @lock.synchronize do
          now = monotonic_now
          traces.each do |trace|
            time_since = [now- trace.time, 0].max
            trace.time = now
            trace.metric.increment(
              trace.labels.merge(worker: @worker.object_id),
              time_since,
            )
          end
        end
      end

      def trace(metric, labels = {}, &block)
        start(metric)
        block.call
      ensure
        stop(metric)
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

      # We're doing duration arithmetic which should make use of monotonic clocks, to avoid
      # changes to the system time from affecting our metrics.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def initialize(
      queue: DEFAULT_QUEUE,
      wake_interval: DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: DEFAULT_LOCK_CURSOR_EXPIRY
    )
      @queue = queue
      @wake_interval = wake_interval
      @locker = Locker.new(queue: queue, cursor_expiry: lock_cursor_expiry)
      @collector = Collector.new(self)
      @stop = false # instruct worker to stop
      @stopped =  false # mark worker as having stopped
    end

    attr_reader :metrics

    def work_loop
      return if @stop

      @collector.trace(RunningSecondsTotal) do
        loop do
          case event = work
          when :job_not_found, :postgres_error
            Que.logger&.info(event: "que.#{event}", wake_interval: @wake_interval)
            @collector.trace(SleepingSecondsTotal) { sleep(@wake_interval) }
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
          return :job_not_found if job.nil?

          log_keys = {
            priority: job["priority"],
            queue: job["queue"],
            handler: job["job_class"],
            job_class: job["job_class"],
            job_error_count: job["error_count"],
            que_job_id: job["job_id"],
          }

          labels = {
            job_class: job["job_class"], priority: job["priority"], queue: job["queue"],
          }

          begin
            Que.logger&.info(
              log_keys.merge(
                event: "que_job.job_begin",
                msg: "Job acquired, beginning work",
              )
            )

            klass = class_for(job[:job_class])

            # Note the time spent waiting in the queue before being processed
            JobsLatencySecondsTotal.increment(labels, job[:latency])

            duration = Benchmark.measure do
              # TODO: _run -> run_and_destroy(*job[:args])
              @collector.trace(JobsWorkedSecondsTotal, labels) { klass.new(job)._run }
              JobsWorkedTotal.increment(labels, 1)
            end.real

            Que.logger&.info(
              log_keys.merge(
                event: "que_job.job_worked",
                msg: "Successfully worked job",
                duration: duration,
              )
            )
          rescue => error
            Que.logger&.error(
              log_keys.merge(
                event: "que_job.job_error",
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
      :postgres_error
    end

    def stop!
      @stop = true
    end

    def stopped?
      @stopped
    end

    def collect_metrics
      @collector.collect
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

    def class_for(string)
      Que.constantize(string)
    end

    # We're doing duration arithmetic which should make use of monotonic clocks, to avoid
    # changes to the system time from affecting our metrics.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
