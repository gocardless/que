# frozen_string_literal: true

require_relative "worker"

module Que
  class WorkerGroup
    DEFAULT_STOP_TIMEOUT = 5 # seconds
    METRICS = [
      ActiveWorkersCount = Prometheus::Client::Gauge.new(
        :que_worker_group_active_workers_count,
        docstring: "Number of active workers",
      ),

      ExpectedWorkersCount = Prometheus::Client::Gauge.new(
        :que_worker_group_expected_workers_count,
        docstring: "Number of configured workers",
      ),
    ].freeze

    def self.start(count, listen: false, **kwargs)
      Que.logger.info(
        msg: "Starting workers",
        event: "que.worker.start",
        worker_count: count,
      )

      wakeup = { mutex: Mutex.new, condvar: ConditionVariable.new } if listen

      workers = Array.new(count) { Worker.new(wakeup: wakeup, **kwargs) }
      worker_threads = workers.map { |worker| Thread.new { worker.work_loop } }

      listener = start_listener(kwargs, wakeup) if listen

      # We want to ensure that our control flow for Que threads and our metric endpoints
      # are prioritised above CPU intensive work of jobs. If people use the metrics
      # endpoint as a liveness check then its essential we don't timeout when we do busy
      # work.
      #
      # We can set our worker thread priority to be a value less than our parent thread to
      # ensure this is the case. Different Ruby runtimes have different priority systems,
      # but -10 should do the trick for all of them.
      worker_threads.each_with_index do |thread, index|
        thread.priority = Thread.current.priority - 10
        thread.name = "worker-thread-#{index}"
      end

      new(workers, worker_threads, listener, wakeup)
    end

    def self.start_listener(kwargs, wakeup)
      queue = kwargs[:queue] || Worker::DEFAULT_QUEUE
      queues = Array(queue).concat(Array(kwargs[:secondary_queues])).uniq

      Listener.new(queues: queues, wakeup: wakeup).start
    end
    private_class_method :start_listener

    def initialize(workers, worker_threads, listener = nil, wakeup = nil)
      @workers = workers
      @worker_threads = worker_threads
      @listener = listener
      @wakeup = wakeup
    end

    attr_reader :workers

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
    end

    def stop(timeout = DEFAULT_STOP_TIMEOUT)
      Que.logger.info(msg: "Asking workers to finish", event: "que.worker.finish_wait")

      @workers.each(&:stop!)

      # If workers are parked waiting on a notification (rather than plain polling),
      # wake them immediately so they notice @stop without waiting out wake_interval.
      wake_all_workers!

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

      @listener&.stop

      Que.logger.info(msg: "All workers have finished", event: "que.worker.finish")
    end

    private

    def wake_all_workers!
      return unless @wakeup

      @wakeup.fetch(:mutex).synchronize { @wakeup.fetch(:condvar).broadcast }
    end
  end
end
