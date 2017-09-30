# frozen_string_literal: true

class FakeJob < Que::Job
  @log = []

  class << self
    attr_accessor :log
  end

  def run(x)
    self.class.log << x
  end
end
