# frozen_string_literal: true

require "English"
require "net/http"

RSpec.describe "Worker health check", :smoke_test do # rubocop:disable RSpec/DescribeClass
  # Use a short wake interval so workers complete at least one cycle before we
  # probe, without having to wait the default 5 seconds.
  let(:wake_interval) { 0.1 }
  let(:metrics_port) { 8081 }

  def spawn_que(task_file)
    Process.spawn(
      "bundle exec bin/que #{task_file} " \
      "--metrics-port=#{metrics_port} " \
      "--wake-interval=#{wake_interval}",
    )
  end

  def health_check_response
    Net::HTTP.get_response(URI("http://0.0.0.0:#{metrics_port}/"))
  end

  context "when workers are healthy" do
    it "returns 200" do
      pid = spawn_que("./tasks/smoke_test.rb")
      sleep 3

      response = health_check_response

      expect(response.code).to eq("200")
      expect(response.body).to eq("healthy")
    ensure
      Process.kill("INT", pid)
      Process.wait(pid)
    end
  end

  context "when workers have a persistent postgres error" do
    it "returns 503" do
      pid = spawn_que("./tasks/smoke_test_unhealthy.rb")
      sleep 3

      response = health_check_response

      expect(response.code).to eq("503")
      expect(response.body).to eq("unhealthy")
    ensure
      Process.kill("INT", pid)
      Process.wait(pid)
    end
  end
end
