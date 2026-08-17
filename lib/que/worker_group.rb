# frozen_string_literal: true

require_relative "worker"
require_relative "centralized_worker"
require_relative "locker"
require_relative "centralized_locker"
require_relative "job_buffer"

module Que
  class WorkerGroup
    DEFAULT_STOP_TIMEOUT = 5 # seconds

    # :legacy - each Worker owns its own Locker and independently polls Postgres (the
    #   architecture Que has always used). Safe, proven default.
    # :centralized - a single CentralizedLocker per process, batching lock queries into a
    #   shared JobBuffer that CentralizedWorker threads pull from. Reduces the number of
    #   concurrent lock queries hitting Postgres from one-per-worker-thread to
    #   one-per-process, at the cost of being newer and less battle-tested. See README
    #   for guidance on rolling this out.
    ARCHITECTURES = %i[legacy centralized].freeze
    DEFAULT_ARCHITECTURE = :legacy

    METRICS = [
      ActiveWorkersCount = Prometheus::Client::Gauge.new(
        :que_worker_group_active_workers_count,
        docstring: "Number of active workers",
      ),

      ExpectedWorkersCount = Prometheus::Client::Gauge.new(
        :que_worker_group_expected_workers_count,
        docstring: "Number of configured workers",
      ),

      LockerAliveGauge = Prometheus::Client::Gauge.new(
        :que_worker_group_locker_alive,
        docstring: "Whether this process's single CentralizedLocker thread is alive " \
                   "(1) or dead (0). Only meaningful with architecture: :centralized - " \
                   "the CentralizedLocker is what polls Postgres for jobs there, so if " \
                   "it's dead, no worker in this process will ever find new work. " \
                   "Always 0 under architecture: :legacy, where there is no single " \
                   "locker thread.",
      ),
    ].freeze

    def self.start(
      count,
      architecture: DEFAULT_ARCHITECTURE,
      queue: Worker::DEFAULT_QUEUE,
      wake_interval: Worker::DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: wake_interval,
      lock_window: nil,
      lock_budget: nil,
      secondary_queues: [],
      run_at_cursor: false
    )
      unless ARCHITECTURES.include?(architecture)
        raise ArgumentError,
              "unknown architecture: #{architecture.inspect} (expected one of #{ARCHITECTURES.inspect})"
      end

      Que.logger.info(
        msg: "Starting workers",
        event: "que.worker.start",
        worker_count: count,
        architecture: architecture,
      )

      kwargs = {
        queue: queue,
        wake_interval: wake_interval,
        lock_cursor_expiry: lock_cursor_expiry,
        lock_window: lock_window,
        lock_budget: lock_budget,
        secondary_queues: secondary_queues,
        run_at_cursor: run_at_cursor,
      }

      case architecture
      when :legacy       then start_legacy(count, **kwargs)
      when :centralized  then start_centralized(count, **kwargs)
      end
    end

    def self.start_legacy(
      count, queue:, wake_interval:, lock_cursor_expiry:, lock_window:, lock_budget:, secondary_queues:,
      run_at_cursor:
    )
      workers =
        Array.new(count) do
          Worker.new(
            queue: queue,
            wake_interval: wake_interval,
            lock_cursor_expiry: lock_cursor_expiry,
            lock_window: lock_window,
            lock_budget: lock_budget,
            secondary_queues: secondary_queues,
            run_at_cursor: run_at_cursor,
          )
        end

      new(workers, start_worker_threads(workers), nil, nil)
    end
    private_class_method :start_legacy

    def self.start_centralized(
      count, queue:, wake_interval:, lock_cursor_expiry:, lock_window:, lock_budget:, secondary_queues:,
      run_at_cursor:
    )
      job_buffer = JobBuffer.new(maximum_size: count)

      locker =
        CentralizedLocker.new(
          queue: queue,
          cursor_expiry: lock_cursor_expiry,
          window: lock_window,
          budget: lock_budget,
          secondary_queues: secondary_queues,
          run_at_cursor: run_at_cursor,
          wake_interval: wake_interval,
          job_buffer: job_buffer,
        ).start

      workers =
        Array.new(count) do
          CentralizedWorker.new(queue: queue, wake_interval: wake_interval, job_buffer: job_buffer)
        end

      new(workers, start_worker_threads(workers), locker, job_buffer)
    end
    private_class_method :start_centralized

    # We want to ensure that our control flow for Que threads and our metric endpoints
    # are prioritised above CPU intensive work of jobs. If people use the metrics
    # endpoint as a liveness check then its essential we don't timeout when we do busy
    # work.
    #
    # We can set our worker thread priority to be a value less than our parent thread to
    # ensure this is the case. Different Ruby runtimes have different priority systems,
    # but -10 should do the trick for all of them.
    def self.start_worker_threads(workers)
      worker_threads = workers.map { |worker| Thread.new { worker.work_loop } }

      worker_threads.each_with_index do |thread, index|
        thread.priority = Thread.current.priority - 10
        thread.name = "worker-thread-#{index}"
      end

      worker_threads
    end
    private_class_method :start_worker_threads

    # locker and job_buffer are only present under architecture: :centralized - nil under
    # :legacy, where each worker owns its own locker instead.
    def initialize(workers, worker_threads, locker, job_buffer)
      @workers = workers
      @worker_threads = worker_threads
      @locker = locker
      @job_buffer = job_buffer
    end

    attr_reader :workers, :locker

    def collect_metrics
      # Threads that are no longer running will have either a status of `nil` (terminated
      # with error) or `false` (terminated normally). We count threads that have
      # terminated normally as "active" since the only way for those threads to be in that
      # state is after an explicit invocation of `stop`, which means we're in the process
      # of shutting down the whole worker. Without this, attempting to collect metrics
      # after `stop` has been invoked will report a different number of active vs
      # configured threads which however is expected.
      active_threads = @worker_threads.reject { |thread| thread.status.nil? }

      ActiveWorkersCount.set(active_threads.count)
      ExpectedWorkersCount.set(workers.count)
      LockerAliveGauge.set(@locker&.alive? ? 1 : 0)
    end

    def stop(timeout = DEFAULT_STOP_TIMEOUT)
      Que.logger.info(msg: "Asking workers to finish", event: "que.worker.finish_wait")

      # Under architecture: :centralized, stop polling for new jobs, wake up (and stop)
      # any workers blocked waiting on the buffer, and wait for the locker to
      # drain+unlock anything it had already buffered but that no worker had claimed
      # yet. We do all of this before tearing down worker threads below, so we never
      # hand a freshly-locked job to a worker that's already being asked to stop. Under
      # :legacy there's no shared locker/buffer to stop - each worker's own locker just
      # stops when the worker itself does, below.
      if @locker
        @locker.stop!
        @job_buffer.stop
        @locker.wait_until_stopped
      end

      @workers.each(&:stop!)

      # Asynchronously stop all workers, sending a join method call with a timeout. This
      # is done asynchronously to ensure we start the timeout at the same time for each
      # worker, instead of applying them cumulatively.
      @worker_threads.each_with_index do |thread, idx|
        Thread.new do
          unless thread.join(timeout)
            Que.logger.info(
              msg: "Worker still running - forcing it to stop",
              worker: idx, event: "que.worker.finish_timeout"
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
      @worker_threads.each(&:join)

      Que.logger.info(msg: "All workers have finished", event: "que.worker.finish")
    end
  end
end
