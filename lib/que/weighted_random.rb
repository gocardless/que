# frozen_string_literal: true

class WeightedRandom
  def initialize(weights)
    @weights = weights
    @rng = Random.new
  end

  def rand
    value = rng.rand(100)
    acc = 0

    weights.each do |weight|
      acc += weight.fetch(:weight)
      if value <= acc
        return weight.fetch(:value)
      end
    end
  end

  private

  attr_reader :rng, :weights
end
