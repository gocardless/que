# frozen_string_literal: true

module Que
  module Middleware
    # Rack application that reflects the health of all workers in the worker
    # group. Returns 503 if all workers have encountered a postgres error on
    # their last work cycle, 200 otherwise.
    #
    # A single worker in postgres_error state may be transient; only when all
    # workers are unhealthy is the pod restarted with fresh database connections.
    class WorkerHealthCheck
      def initialize(worker_group)
        @worker_group = worker_group
      end

      def call(_env)
        workers = @worker_group.workers
        if workers.empty? || workers.any?(&:healthy?)
          [200, { "Content-Type" => "text/plain" }, ["healthy"]]
        else
          [503, { "Content-Type" => "text/plain" }, ["unhealthy"]]
        end
      end
    end
  end
end
