# frozen_string_literal: true

require "rack"
require "benchmark"
require "prometheus/client"
require "prometheus/middleware/exporter"

module Que
  class Metrics
    def self.register_metrics(registry)
      return registry if registry.exist?(:que_jobs_worked_total)

      registry.instance_eval do
        counter(:que_jobs_worked_total, "Counter for all jobs processed")
        counter(:que_jobs_error_total, "Counter for all jobs that were run but errored")
        counter(:que_jobs_worked_seconds_total, "Sum of the time taken processing each job class")
        counter(:que_jobs_latency_seconds_total, "Sum of time spent by job and priority waiting in queue")
        counter(:que_worker_sleeping_total, "Number of times worker slept due to no jobs")
        counter(:que_worker_sleeping_seconds_total, "Time spent sleeping, because no jobs")
        counter(:que_worker_running_seconds_total, "Time since starting to work jobs")
        counter(:que_worker_job_exists__total, "Counter of number of attempts to check job existance in locking")
        counter(:que_worker_job_exists_seconds_total, "Time spent checking if job exists as part of locking")
        counter(:que_worker_job_unlock_total, "Counter of number of advisory unlocks")
        counter(:que_worker_job_unlock_seconds_total, "Time spent unlocking advisory job locks")
        counter(:que_worker_job_acquire_total, "Counter of number of attempts to acquire jobs")
        counter(:que_worker_job_acquire_seconds_total, "Sum of time taken to acquire jobs")

        self
      end
    end

    # Start a webserver on the given port to expose Prometheus metrics. This should be
    # given the registry that is used across all workers, to provide metrics for every
    # worker thread.
    def self.expose(registry, port: 8080)
      Que.logger&.info(
        event: "serving_metrics",
        msg: "Serving /metrics endpoint",
        port: port,
      )

      Rack::Handler::WEBrick.run(
        Prometheus::Middleware::Exporter.
          new(Proc.new { [200, {}, ["healthy"]] }, registry: registry), {
            Port: port,
            BindAddress: "0.0.0.0",
            Logger: WEBrick::Log.new("/dev/null"),
            AccessLog: [],
          }
      )
    end

    def initialize(labels: {}, registry: Prometheus::Client.registry)
      @registry = self.class.register_metrics(registry)
      @metrics = @registry.metrics.each_with_object({}) { |m, ms| ms[m.name] = m }
      @base_labels = labels

      # These instance variables all relate to internal running job metrics. They are used
      # to periodically update the jobs_worked_seconds counter.
      @running_job_lock = Mutex.new
      @running_job_labels = nil
      @running_job_last_seen = nil
      @running_job_tracker_stop = start_job_tracker

      # When we get garbage collected, stop the job tracker thread.
      ObjectSpace.define_finalizer(self) { @running_job_tracker_stop.call }
    end

    def trace_start_work(labels = {})
      stop = false

      Thread.new do
        last_timestamp = monotonic_now

        until stop
          timestamp = monotonic_now
          @metrics[:que_worker_running_seconds_total].
            increment(@base_labels.merge(labels), timestamp - last_timestamp)
          last_timestamp = timestamp

          sleep(1) # delay the next update for 1s
        end
      end

      -> { stop = true }
    end

    def trace_sleeping(labels, &block)
      instrument(
        labels,
        @metrics[:que_worker_sleeping_total],
        @metrics[:que_worker_sleeping_seconds_total],
        &block
      )
    end

    def trace_acquire_job(labels, &block)
      instrument(
        labels,
        @metrics[:que_worker_job_acquire_total],
        @metrics[:que_worker_job_acquire_seconds_total],
        &block
      )
    end

    def trace_unlock_job(labels, &block)
      instrument(
        labels,
        @metrics[:que_worker_job_unlock_total],
        @metrics[:que_worker_job_unlock_seconds_total],
        &block
      )
    end

    def trace_job_exists(labels, &block)
      instrument(
        labels,
        @metrics[:que_worker_job_exists_total],
        @metrics[:que_worker_job_exists_seconds_total],
        &block
      )
    end

    # We apply labels for job_class and priority as this provides the cardinality needed
    # for debugging queue performance issues- you typically want to know if a particular
    # job class is taking a long time, or if a priority class is stuck.
    def trace_work_job(job, &block)
      labels = {
        job_class: job["job_class"], priority: job["priority"], queue: job["queue"],
      }
      @metrics[:que_jobs_latency_seconds_total].increment(labels, job[:latency])

      # Note that we've begun processing our job, so we can continually update the counter
      set_running_job(labels)
      block.call

    rescue
      @metrics[:que_jobs_error_total].increment(labels, 1)
      raise

    ensure
      # Once finished with our job, increment our counter by what elapsed between us and
      # the last run of our job tracker. We ensure this so that we track duration of jobs
      # that raise exceptions.
      @metrics[:que_jobs_worked_seconds_total].increment(labels, set_running_job(nil))
      @metrics[:que_jobs_worked_total].increment(labels, 1)
    end

    private

    # If we only track job runtime by incrementing the counter at the end of the job being
    # run, then long jobs will update counters by large amounts only once. This method
    # starts a thread that monitors our currently running job and periodically updates the
    # runtime counter, ensuring we measure long job runtimes gradually.
    def start_job_tracker
      stop = false

      Thread.new do
        until stop do
          @running_job_lock.synchronize do
            next unless @running_job_labels

            timestamp = monotonic_now
            @metrics[:que_jobs_worked_seconds_total].
              increment(@running_job_labels, timestamp - @running_job_last_seen)

            @running_job_last_seen = timestamp
          end

          sleep(0.5) # update jobs worked every .5 seconds
        end
      end

      -> { stop = true }
    end

    # This method provides synchronized access to the running job instance variables,
    # preventing a race between the job tracker thread and us marking a job as having
    # finished. Return the elapsed time for convenience.
    def set_running_job(job_labels, last_seen = monotonic_now)
      @running_job_lock.synchronize do
        # Occassionally the value of elapsed will be computed as a negative number. We're
        # not absolutely certain why, though we should ensure we never pass this to
        # prometheus to avoid raising an exception.
        elapsed = last_seen - @running_job_last_seen if @running_job_last_seen
        elapsed = 0.0 if elapsed && elapsed < 0.0

        @running_job_labels = job_labels
        @running_job_last_seen = last_seen

        elapsed
      end
    end

    # We're doing duration arithmetic which should make use of monotonic clocks, to avoid
    # changes to the system time from affecting our metrics.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Increment the given counter by however long it takes to run the block. Return
    # whatever the block evaluates to. Use Benchmark.measure as it uses monotonic clocks
    # for timing.
    def instrument(labels, counter, duration_counter)
      result = nil
      duration = Benchmark.measure { result = yield }.real
      duration_counter&.increment(@base_labels.merge(labels), duration)

      result
    ensure
      counter&.increment(@base_labels.merge(labels), 1)
    end
  end
end
