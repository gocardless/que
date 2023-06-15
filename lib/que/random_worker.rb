# frozen_string_literal: true

require_relative "worker"
require_relative "weighted_random"

module Que
  class RandomWorker < Worker
    def initialize(
      weighted_queues: [{ weight: 100, value: DEFAULT_QUEUE }],
      wake_interval: DEFAULT_WAKE_INTERVAL,
      lock_cursor_expiry: DEFAULT_WAKE_INTERVAL,
      lock_window: nil,
      lock_budget: nil
    )
      @rng = WeightedRandom.new(weighted_queues)
      @queue_lockers = weighted_queues.each_with_object({}) do |queue, lookup|
        lookup[queue] = Locker.new(
          queue: queue,
          cursor_expiry: lock_cursor_expiry,
          window: lock_window,
          budget: lock_budget,
        )
      end

      super(
        # We need an initial value for queue setting like this means the tracing
        # is aware of the strategy used.
        queue: "weighted_random",
        wake_interval: wake_interval,
        lock_cursor_expiry: lock_cursor_expiry,
        lock_window: lock_window,
        lock_budget: lock_budget,
      )
    end

    def work
      # Use the weighted random queues to select which queue to aquire work from.
      # The idea here is we can use this for queues with fewer jobs inside to
      # optimise our required worker processes and save on SQL connections.
      #
      # Its a little nasty to mutate these values but as this is a proof of
      # concept for now we can revisit this later if it works as intended.
      @queue = @rng.rand
      @locker = @queue_lockers[@queue]

      super
    end
  end
end
