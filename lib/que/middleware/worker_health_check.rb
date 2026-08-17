# frozen_string_literal: true

module Que
  module Middleware
    # Rack application that reflects the health of the worker group's Locker and its
    # workers. Returns 503 if the process's Locker has died or is stuck in a persistent
    # postgres_error state (in which case no worker in this process will ever find new
    # work, regardless of how healthy the workers themselves look), or if every worker
    # itself has encountered a postgres error on its last work cycle. Returns 200
    # otherwise.
    #
    # A single worker in postgres_error state may be transient; only when the Locker is
    # unhealthy, or all workers are unhealthy, is the pod restarted with fresh database
    # connections.
    class WorkerHealthCheck
      def initialize(worker_group)
        @worker_group = worker_group
      end

      def call(_env)
        if healthy?
          [200, { "Content-Type" => "text/plain" }, ["healthy"]]
        else
          [503, { "Content-Type" => "text/plain" }, ["unhealthy"]]
        end
      end

      private

      def healthy?
        return false if locker_unhealthy?

        workers = @worker_group.workers
        workers.empty? || workers.any?(&:healthy?)
      end

      def locker_unhealthy?
        locker = @worker_group.locker
        locker && !locker.healthy?
      end
    end
  end
end
