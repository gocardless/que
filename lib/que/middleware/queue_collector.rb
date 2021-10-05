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

      QueuedPastDue = Prometheus::Client::Gauge.new(
        :que_queue_queued_past_due_seconds,
        docstring: "Max seconds past due, by job_class/priority/due/failed",
        labels: %i[queue job_class priority due failed],
      )

      def initialize(app, options = {})
        @app = app
        @registry = options.fetch(:registry, Prometheus::Client.registry)
        @refresh_interval = options.fetch(:refresh_interval, 20.seconds)
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
        QueuedPastDue.values.each { |labels, _| QueuedPastDue.set(0.0, labels: labels) }

        refresh_materialized_view if due_refresh?

        # Now we can safely update our gauges, touching only those that exist
        # in our queue
        Que.execute("select * from que_jobs_summary").each do |labels|
          metric_labels = {
            queue: labels["queue"],
            job_class: labels["job_class"],
            priority: labels["priority"],
            due: labels["due"],
            failed: labels["failed"],
          }
          Queued.set(
            labels["count"],
            labels: metric_labels,
          )
          QueuedPastDue.set(
            labels["max_seconds_past_due"],
            labels: metric_labels,
          )
        end

        @app.call(env)
      end
      # rubocop:enable Metrics/AbcSize

      def refresh_materialized_view
        # Ensure generating metrics never take more than 5000ms to execute. If we can't
        # grab the lock within 100ms, then we know someone else is refreshing the view,
        # and should quit silently
        Que.transaction do
          Que.execute("set local lock_timeout='100ms';")
          Que.execute("set local statement_timeout='5000ms';")
          Que.execute("refresh materialized view que_jobs_summary;")
          Que.execute("analyze que_jobs_summary;")
        end
      rescue StandardError => e
        Que.logger.info(event: "refresh_materialized_view", error: e.to_s)
      end

      def due_refresh?
        since_analyze = Que.execute(<<~SQL).first&.fetch("since_analyze")
          select case
            when last_analyze is not null then extract(epoch from now() - last_analyze)
            else null
          end as since_analyze
          from pg_stat_user_tables
          where relname = 'que_jobs_summary';
        SQL

        since_analyze.nil? || since_analyze > @refresh_interval
      end
    end
  end
end
