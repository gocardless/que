# frozen_string_literal: true

class SleepJob < Kent::Job
  def run(duration)
    sleep(duration)
  end
end
