# frozen_string_literal: true

class RescueSleepJob < Que::Job
  def run(duration)
    begin
      5.downto(0) do |d|
        sleep(d)
      end
    rescue => e
      Thread.new { puts "Caught an error: #{e.class} => #{e.to_s}" }
    end
  end
end
