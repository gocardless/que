require 'monitor'

module Que
  class Worker
    # Each worker has a thread that does the actual work of running jobs.
    # Since both the worker's thread and whatever thread is managing the
    # worker are capable of affecting the worker's state, we need to
    # synchronize access to it.
    include MonitorMixin

    attr_reader :thread, :state, :queue

    def initialize(queue = '')
      super() # For MonitorMixin.
      @queue  = queue
      @state  = :working
      @thread = Thread.new { work_loop }
      @thread.abort_on_exception = true
    end

    def alive?
      !!@thread.status
    end

    def sleeping?
      synchronize { _sleeping? }
    end

    def working?
      synchronize { @state == :working }
    end

    def wake!
      synchronize do
        if sleeping?
          # Have to set the state here so that another thread checking
          # immediately after this won't see the worker as asleep.
          @state = :working
          @thread.wakeup
          true
        end
      end
    end

    # This needs to be called when trapping a signal, so it can't lock the monitor.
    def stop
      @stop = true
      @thread.wakeup if _sleeping?
    end

    def wait_until_stopped
      wait while alive?
    end

    private

    # Sleep very briefly while waiting for a thread to get somewhere.
    def wait
      sleep 0.0001
    end

    def _sleeping?
      if @state == :sleeping
        # There's a very small period of time between when the Worker marks
        # itself as sleeping and when it actually goes to sleep. Only report
        # true when we're certain the thread is sleeping.
        wait until @thread.status == 'sleep'
        true
      end
    end

    def work_loop
      loop do
        cycle = nil

        if Que.mode == :async
          time   = Time.now
          result = Job.work(queue)

          case result[:event]
          when :job_unavailable
            cycle = false
            result[:level] = :debug
          when :job_race_condition
            cycle = true
            result[:level] = :debug
          when :job_worked
            cycle = true
            result[:elapsed] = (Time.now - time).round(5)
          when :job_errored
            # For PG::Errors, assume we had a problem reaching the database, and
            # don't hit it again right away.
            cycle = !result[:error].is_a?(PG::Error)
            result[:error] = {:class => result[:error].class.to_s, :message => result[:error].message}
          else
            raise "Unknown Event: #{result[:event].inspect}"
          end

          Que.log(result)
        end

        synchronize { @state = :sleeping unless cycle || @stop }
        sleep if @state == :sleeping
        break if @stop
      end
    ensure
      @state = :stopped
    end

    class << self
      def workers
        warn "Que.default_worker_pool.workers has been deprecated and will be removed in a future version of Que"
        Que.default_worker_pool.workers
      end
    end
  end
end
