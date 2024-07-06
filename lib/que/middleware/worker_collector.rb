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

        register(*WorkerGroup::METRICS)
        register(*Worker::METRICS)
        register(*Locker::METRICS)
      end

      def call(env)
        @worker_group.collect_metrics
        @worker_group.workers.each(&:collect_metrics)
        @app.call(env)
      end

      private

      # rubocop:disable Style/RedundantBegin, Lint/SuppressedException
      def register(*metrics)
        begin
          metrics.each do |metric|
            @registry.register(metric)
          end
        rescue Prometheus::Client::Registry::AlreadyRegisteredError
        end
      end
      # rubocop:enable Style/RedundantBegin, Lint/SuppressedException
    end
  end
end
