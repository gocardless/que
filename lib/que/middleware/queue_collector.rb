# frozen_string_literal: true

require "prometheus/client"

module Que
  module Middleware
    # Updates prometheus queue level metrics. This should be placed just before any rack
    # middleware that serves prometheus metrics in order to generate fresh values just
    # before responding a scrape.
    class QueueCollector
      Queued = Prometheus::Client::Gauge.new(
        :que_queue_queued, "Number of jobs in the queue, by job_class/priority/due",
      )

      QUEUE_VIEW_SQL = <<~SQL.freeze
        select queue, job_class, priority
             , (case when (retryable AND run_at < now()) then 'true' else 'false' end) as due
             , count(*)
          from que_jobs
         group by 1, 2, 3, 4;
      SQL

      def initialize(app, options = {})
        @app = app
        @registry = options.fetch(:registry, Prometheus::Client.registry)
        @registry.register(Queued) rescue Prometheus::Client::Registry::AlreadyRegisteredError
      end

      def call(env)
        # Reset all the previously observed values back to zero, ensuring we only ever
        # report metric values that are current in every scrape.
        Queued.values.each { |labels, _| Queued.set(labels, 0.0) }

        # Now we can safely update our gauges, touching only those that exist in our queue
        Que.execute(QUEUE_VIEW_SQL).each do |labels|
          Queued.set(
            {
              queue: labels["queue"],
              job_class: labels["job_class"],
              priority: labels["priority"],
              due: labels["due"],
            },
            labels["count"],
          )
        end

        @app.call(env)
      end
    end
  end
end
