# frozen_string_literal: true

module Que
  # Provide a mechanism to throttle resource usage, by specifying a target budget of
  # resource time to be consumed over a rolling window.
  #
  # This is not thread-safe, and should be used by only one thread at any one time.
  class LeakyBucket
    def initialize(window:, budget:, clock: Clock)
      @window = window
      @budget = budget
      @clock = clock
      @ratio = budget / window
      @remaining = 0.0
      @last_refill = nil
    end

    class Clock
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def self.sleep(duration)
        Kernel.sleep(duration)
      end
    end

    # Observe resource usage from within the provided block. This consumes time that
    # remains in the bucket, and should only be called after the bucket has been refilled.
    def observe
      start = @clock.now
      result = yield
    ensure
      duration = @clock.now - start
      @remaining -= duration

      result
    end

    # Wait for the bucket to be refilled, given the time that has elapsed since the last
    # refill. This method will block until the remaining budget has become positive.
    def refill
      refill_time = @clock.now
      time_since_refill = refill_time - (@last_refill || refill_time)
      grant = @ratio * time_since_refill

      @last_refill = refill_time
      @remaining = [@budget, @remaining + grant].min

      # Sleep long enough that the subsequent refill would provide a grant large enough to
      # make our balance positive
      if @remaining < 0.0
        @clock.sleep(-@remaining / @ratio)
      end
    end

    private

    def catch_error(&block)
      result = block.call
      [result, nil]
    rescue StandardError => err
      [result, err]
    end
  end
end
