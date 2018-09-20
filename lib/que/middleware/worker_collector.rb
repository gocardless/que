# frozen_string_literal: true

require "prometheus/client"

module Que
  module Middleware
    class WorkerCollector
      def initialize(app, options = {})
        @app = app
        @workers = options.fetch(:workers) # WorkerGroup
        @registry = options.fetch(:registry, Prometheus::Client.registry)

        register(*Worker::METRICS)
        register(*Locker::METRICS)
      end

      def call(env)
        @workers.each(&:collect_metrics)
        @app.call(env)
      end

      private

      def register(*metrics)
        metrics.each do |metric|
          begin
            @registry.register(metric)
          rescue Prometheus::Client::Registry::AlreadyRegisteredError
          end
        end
      end
    end
  end
end
