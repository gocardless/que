# frozen_string_literal: true

module Que
  module Middleware
    class WorkerCollector
      def initialize(app, options = {})
        @app = app
        @workers = options.fetch(:workers) # WorkerGroup
      end

      def call(env)
        @workers.each(&:collect_metrics)
        @app.call(env)
      end
    end
  end
end
