module Que
  class WorkerPool
    attr_reader :queue, :mode, :wake_interval, :worker_count

    def initialize(queue)
      @queue = queue
      @mode  = :off

      # Setting Que.wake_interval = nil should ensure that the wrangler thread
      # doesn't wake up a worker again, even if it's currently sleeping for a
      # set period. So, we double-check that @wake_interval is set before waking
      # a worker, and make sure to wake up the wrangler when @wake_interval is
      # changed in Que.wake_interval= below.
      @wake_interval = 5

      # Four workers is a sensible default for most use cases.
      @worker_count = 4
    end

    # In order to work in a forking webserver, we need to be able to accept
    # worker_count and wake_interval settings without actually instantiating
    # the relevant threads until the mode is actually set to :async in a
    # post-fork hook (since forking will kill any running background threads).

    def mode=(mode)
      Que.log :event => 'mode_change', :value => mode.to_s
      @mode = mode

      if mode == :async
        set_up_workers
        wrangler
      end
    end

    def worker_count=(count)
      Que.log :event => 'worker_count_change', :value => count.to_s
      @worker_count = count
      set_up_workers if mode == :async
    end

    def workers
      @workers ||= []
    end

    def wake_interval=(interval)
      @wake_interval = interval
      wrangler.wakeup if mode == :async
    end

    def wake!
      workers.find(&:wake!)
    end

    def wake_all!
      workers.each(&:wake!)
    end

    private

    def set_up_workers
      if worker_count > workers.count
        workers.push(*(worker_count - workers.count).times.map{Worker.new(queue)})
      elsif worker_count < workers.count
        workers.pop(workers.count - worker_count).each(&:stop).each(&:wait_until_stopped)
      end
    end

    def wrangler
      @wrangler ||= Thread.new do
        loop do
          sleep(*@wake_interval)
          wake! if @wake_interval && mode == :async
        end
      end
    end
  end
end
