# frozen_string_literal: true

require "prometheus/client"
require "prometheus_gcstat"

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
        @memstats = Prometheus::MemoryStats.new(Prometheus::Client.registry, interval: 10)
        @memstats.start

        register(*Worker::METRICS)
        register(*Locker::METRICS)
      end

      def call(env)
        @worker_group.workers.each(&:collect_metrics)
        @app.call(env)
      end

      private

      # rubocop:disable Lint/HandleExceptions
      # rubocop:disable Style/RedundantBegin
      def register(*metrics)
        begin
          metrics.each do |metric|
            @registry.register(metric)
          end
        rescue Prometheus::Client::Registry::AlreadyRegisteredError
        end
      end
      # rubocop:enable Style/RedundantBegin
      # rubocop:enable Lint/HandleExceptions
    end
  end
end
