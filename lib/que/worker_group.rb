# frozen_string_literal: true

require_relative "worker"

module Que
  class WorkerGroup
    DEFAULT_STOP_TIMEOUT = 5 # seconds

    def self.start(count, **kwargs)
      Que.logger.info(
        msg: "Starting workers",
        event: "que.worker.start",
        worker_count: count,
      )

      workers = Array.new(count) { Worker.new(**kwargs) }
      worker_threads = workers.map { |worker| Thread.new { worker.work_loop } }

      # We want to ensure that our control flow for Que threads and our metric endpoints
      # are prioritised above CPU intensive work of jobs. If people use the metrics
      # endpoint as a liveness check then its essential we don't timeout when we do busy
      # work.
      #
      # We can set our worker thread priority to be a value less than our parent thread to
      # ensure this is the case. Different Ruby runtimes have different priority systems,
      # but -10 should do the trick for all of them.
      worker_threads.each { |thread| thread.priority = Thread.current.priority - 10 }

      new(workers, worker_threads)
    end

    def initialize(workers, worker_threads)
      @workers = workers
      @worker_threads = worker_threads
    end

    attr_reader :workers

    def stop(timeout = DEFAULT_STOP_TIMEOUT)
      Que.logger.info(msg: "Asking workers to finish", event: "que.worker.finish_wait")

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
