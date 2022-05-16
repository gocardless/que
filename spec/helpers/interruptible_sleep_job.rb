# frozen_string_literal: true

class InterruptibleSleepJob < Kent::Job
  @log = []

  class << self
    attr_accessor :log
  end

  def run(duration)
    5.times do
      return if stop?

      sleep(duration)
      self.class.log << [:run, duration]
    end
  end
end
