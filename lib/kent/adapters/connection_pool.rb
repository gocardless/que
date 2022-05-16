# frozen_string_literal: true

module Kent
  module Adapters
    class ConnectionPool < Base
      def initialize(pool)
        @pool = pool
        super
      end

      def checkout(&block)
        @pool.with(&block)
      end
    end
  end
end
