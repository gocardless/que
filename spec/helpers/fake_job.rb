# frozen_string_literal: true

class FakeJob < Kent::Job
  @log = []

  class << self
    attr_accessor :log
  end

  def run(arg)
    self.class.log << arg
  end
end
