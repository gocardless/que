# frozen_string_literal: true

class SleepJob < Que::Job
  def run(duration)
    sleep(duration)
  end
end
