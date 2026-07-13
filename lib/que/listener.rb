# frozen_string_literal: true

module Que
  # Listens for pg_notify() messages announcing that a job has become
  # available on one of the given queues, and uses them to wake up idle
  # workers early instead of leaving them to wait out their next poll.
  #
  # This is a supplement to polling, not a replacement for it - workers still
  # poll on every cycle regardless of whether they were woken by a
  # notification or by their poll interval elapsing. That means a missed or
  # delayed notification (the listener hasn't (re)connected yet, a
  # notification arrives while we're reconnecting, etc) only costs the
  # latency of the next poll rather than losing the job.
  #
  # Requires a dedicated connection for its entire lifetime (to hold the
  # LISTEN), which for pooled adapters (ActiveRecord/Sequel/Pond) means the
  # pool needs capacity for one extra connection per Listener on top of
  # however many workers are checking connections out to run queries.
  class Listener
    RECONNECT_WAIT = 1.0 # seconds
    POLL_TIMEOUT = 1.0 # seconds; bounds how quickly #stop is noticed

    def self.channel_for_queue(queue)
      "que_job_available_#{queue}"
    end

    def initialize(queues:, wakeup:)
      @queues = queues
      @wakeup = wakeup
      @stop = false
    end

    def start
      @thread = Thread.new { run }
      @thread.name = "que-listener"
      self
    end

    def stop
      @stop = true
      @thread&.join
    end

    private

    def run
      until @stop
        begin
          listen_and_wait
        rescue PG::Error, Adapters::UnavailableConnection => e
          Que.logger&.warn(
            event: "que.listener.connection_error",
            msg: "Listener lost its connection, reconnecting",
            error: e.inspect,
          )
          sleep(RECONNECT_WAIT) unless @stop
        end
      end
    end

    def listen_and_wait
      Que.adapter.checkout do |conn|
        listen(conn)

        begin
          wait_for_notifications(conn) until @stop
        ensure
          unlisten(conn)
        end
      end
    end

    def listen(conn)
      @queues.each do |queue|
        conn.exec(%(LISTEN #{conn.quote_ident(self.class.channel_for_queue(queue))}))
      end
    end

    def unlisten(conn)
      conn.exec("UNLISTEN *")
      nil while conn.notifies
    end

    def wait_for_notifications(conn)
      conn.wait_for_notify(POLL_TIMEOUT) { wake! }
    end

    def wake!
      @wakeup.fetch(:mutex).synchronize { @wakeup.fetch(:condvar).broadcast }
    end
  end
end
