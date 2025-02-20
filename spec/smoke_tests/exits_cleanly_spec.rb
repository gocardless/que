# frozen_string_literal: true

require "English"
require "open3"
require "net/http"

RSpec.describe "Exits cleanly", :smoke_test do # rubocop:disable RSpec/DescribeClass
  it "exits cleanly when the process receives a SIGINT" do
    pid = Process.spawn("bundle exec bin/que ./tasks/smoke_test.rb --metrics-port=8080")
    sleep 3

    response = Net::HTTP.get_response(URI("http://0.0.0.0:8080/metrics"))

    expect(response.code).to eq("200")
    expect(response.body).to include("que_locker_acquire_seconds_total")

    Process.kill("INT", pid)
    Process.wait(pid)
    process_status = $CHILD_STATUS

    expect(process_status.exitstatus).to eq(0)
  end
end
