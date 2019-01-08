# frozen_string_literal: true

require "monitor"

module Que
  module Adapters
    class PG < Base
      attr_reader :lock

      def initialize(connection)
        @connection = connection
        @lock = Monitor.new # Must be re-entrant.
        super
      end

      def checkout
        @lock.synchronize { yield @connection }
      end
    end
  end
end
