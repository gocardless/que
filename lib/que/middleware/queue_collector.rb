# frozen_string_literal: true

require "prometheus/client"

module Que
  module Middleware
    # Updates prometheus queue level metrics. This should be placed just before any rack
    # middleware that serves prometheus metrics in order to generate fresh values just
    # before responding a scrape.
    class QueueCollector
      Queued = Prometheus::Client::Gauge.new(
        :que_queue_queued,
        docstring: "Number of jobs in the queue, by job_class/priority/due/failed",
        labels: %i[queue job_class priority due failed],
      )
      DeadTuples = Prometheus::Client::Gauge.new(
        :que_dead_tuples,
        docstring: "Number of dead tuples in the que_jobs table",
      )
      QUEUE_VIEW_SQL = <<~SQL
        select queue, job_class, priority
             , (case when (retryable AND run_at < now()) then 'true' else 'false' end) as due
             , (case when (NOT retryable AND error_count > 0) then 'true' else 'false' end) as failed
             , count(*)
             from que_jobs
         group by 1, 2, 3, 4, 5;
      SQL

      DEAD_TUPLES_SQL = <<~SQL
        select n_dead_tup
          from pg_stat_user_tables
         where relname='que_jobs';
      SQL

      def initialize(app, options = {})
        @app = app
        @registry = options.fetch(:registry, Prometheus::Client.registry)
        begin
          @registry.register(Queued)
        rescue StandardError
          Prometheus::Client::Registry::AlreadyRegisteredError
        end
        begin
          @registry.register(DeadTuples)
        rescue StandardError
          Prometheus::Client::Registry::AlreadyRegisteredError
        end
      end

      # rubocop:disable Metrics/AbcSize
      def call(env)
        # Reset all the previously observed values back to zero, ensuring we only ever
        # report metric values that are current in every scrape.
        Queued.values.each { |labels, _| Queued.set(0.0, labels: labels) }

        Que.transaction do
          # Ensure metric queries never take more than 500ms to execute, preventing our
          # metric collector from hurting the database when it's already under pressure.
          Que.execute("set local statement_timeout='500ms';")

          # Now we can safely update our gauges, touching only those that exist
          # in our queue
          Que.execute(QUEUE_VIEW_SQL).each do |labels|
            Queued.set(
              labels["count"],
              labels: {
                queue: labels["queue"],
                job_class: labels["job_class"],
                priority: labels["priority"],
                due: labels["due"],
                failed: labels["failed"],
              },
            )
          end

          # DeadTuples has no labels, we can expect this to be a single numeric value
          DeadTuples.set(Que.execute(DEAD_TUPLES_SQL).first&.fetch("n_dead_tup"))
        end

        @app.call(env)
      end
      # rubocop:enable Metrics/AbcSize
    end
  end
end
