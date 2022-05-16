# frozen_string_literal: true

module Kent
  module Adapters
    class Pond < Base
      def initialize(pond)
        @pond = pond
        super
      end

      def checkout(&block)
        @pond.checkout(&block)
      end
    end
  end
end
