# frozen_string_literal: true

require "prometheus/client"

module Que
  module Middleware
    # When called, will ask each worker to update the prometheus metrics that it exports,
    # ensuring that immediately after calling metrics like worker run seconds are
    # up-to-date.
    #
    # This should be placed just before any middleware that serves prometheus metrics.
    class WorkerCollector
      def initialize(app, options = {})
        @app = app
        @worker_group = options.fetch(:worker_group)
        @registry = options.fetch(:registry, Prometheus::Client.registry)

        register(*Worker::METRICS)
        register(*Locker::METRICS)
      end

      def call(env)
        @worker_group.workers.each(&:collect_metrics)
        @app.call(env)
      end

      private

      # rubocop:disable Lint/HandleExceptions
      def register(*metrics)
        begin
          metrics.each do |metric|
            @registry.register(metric)
          end
        rescue Prometheus::Client::Registry::AlreadyRegisteredError
        end
      end
      # rubocop:enable Lint/HandleExceptions
    end
  end
end
