# frozen_string_literal: true

require "benchmark"
require "que/metrics"
require "que/locker"

module Que
  class JobTimeoutError < StandardError; end

  class Worker
    DEFAULT_QUEUE = ''
    DEFAULT_WAKE_INTERVAL = 5
    DEFAULT_LOCK_CURSOR_EXPIRY = 0 # seconds
    DEFAULT_STOP_TIMEOUT = 5 # seconds

    # Start worker_count number of threaded workers, returning a proc that can be called
    # to stop the workers from working.
    def self.start_workers(worker_count, metrics_labels: {}, **kwargs)
      Que.logger.info(msg: 'Starting workers', event: 'que.worker.start', worker_count: worker_count)

      # Create each worker with a distinct ID in order to differentiate each workers
      # prometheus metrics.
      workers = Array.new(worker_count) do |id|
        Worker.new(**kwargs.merge(metrics_labels: metrics_labels.merge(worker: id)))
      end

      worker_threads = workers.map { |worker| Thread.new { worker.work_loop } }

      -> (stop_timeout = DEFAULT_STOP_TIMEOUT) do
        Que.logger.info(msg: "Asking workers to finish", event: "que.worker.finish_wait")

        workers.each(&:stop!)

        # Asynchronously stop all workers, sending a join method call with a timeout. This
        # is done asynchronously to ensure we start the timeout at the same time for each
        # worker, instead of applying them cumulatively.
        worker_threads.each_with_index do |thread, idx|
          Thread.new do
            unless thread.join(stop_timeout)
              Que.logger.info(
                msg: "Worker still running - forcing it to stop",
                worker: idx, event: "que.worker.finish_timeout",
              )

              # Caveat that this API (Thread.raise) can be dangerous in Ruby. It can leave
              # resources in strange states as the exception is trapped immediately in the
              # target thread, potentially during code that expected no interruptions.
              #
              # We can expect this exception to be raised just before our process receives
              # a SIGKILL, so any hanging resources are probably about to be claimed by
              # the OS after process death. Given our impending doom, the benefit of
              # having Que track timeouts against the affected job seems worth the risk of
              # short-lived undefined behaviour.
              #
              # If we begin to see issues with this approach (strange TCP connection
              # states, connection pool issues, etc) then we should re-evaluate.
              thread.raise(JobTimeoutError, "Job exceeded timeout when requested to stop")
            end
          end
        end

        # We now know the thread is either finished or has raised an exception. The final
        # join gives the worker thread time to finish its work loop and record the timeout
        # exception against the job it was working.
        worker_threads.each(&:join)

        Que.logger.info(msg: "All workers have finished", event: "que.worker.finish")
      end
    end

    def initialize(
      queue: DEFAULT_QUEUE,
      wake_interval: DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: DEFAULT_LOCK_CURSOR_EXPIRY,
      metrics_labels: {},
      priority_threshold: 0,
      metrics_registry: Prometheus::Client.registry
    )
      @queue = queue
      @wake_interval = wake_interval
      @metrics = Metrics.new(labels: metrics_labels, registry: metrics_registry)
      @locker = Locker.new(queue: queue, cursor_expiry: lock_cursor_expiry, metrics: metrics)
      @stop = false
    end

    attr_reader :metrics

    def work_loop
      return if @stop
      stop_trace = @metrics.trace_start_work(queue: @queue)

      loop do
        case event = work
        when :job_not_found, :postgres_error
          Que.logger&.info(event: "que.#{event}", wake_interval: @wake_interval)
          @metrics.trace_sleeping(queue: @queue) { sleep(@wake_interval) }
        when :job_worked
          nil # immediately find a new job to work
        end

        break if @stop
      end
    ensure
      stop_trace.call if stop_trace
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

          begin
            Que.logger&.info(
              log_keys.merge(
                event: "que_job.job_begin",
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
  end
end
