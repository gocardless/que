# frozen_string_literal: true

$LOAD_PATH << File.expand_path(__FILE__, "../lib")

require "que"
require "rspec"
require "active_record"

require_relative "helpers/create_user"
require_relative "helpers/exceptional_job"
require_relative "helpers/fake_job"
require_relative "helpers/que_job"
require_relative "helpers/sleep_job"
require_relative "helpers/interruptible_sleep_job"
require_relative "helpers/user"
require_relative "active_record_with_lock_spec_helper"

def postgres_now
  ActiveRecord::Base.connection.execute("SELECT NOW();")[0]["now"]
end

def establish_database_connection
  ActiveRecord::Base.establish_connection(
    adapter: "postgresql",
    host: ENV.fetch("PGHOST", "localhost"),
    user: ENV.fetch("PGUSER", "ubuntu"),
    password: ENV.fetch("PGPASSWORD", "password"),
    database: ENV.fetch("PGDATABASE", "que-test"),
  )
end

establish_database_connection

# Make sure our test database is prepared to run Que
Que.connection =
  case ENV["ADAPTER"]
  when "ActiveRecordWithLock" then active_record_with_lock_adapter_connection
  else ActiveRecord
  end

Que.migrate!

# Ensure we have a logger, so that we can test the code paths that log
Que.logger = Logger.new(File::NULL)

RSpec.configure do |config|
  # Run only specific adapter files based on the adapter class
  spec_dir = "./spec/lib"
  # Construct the path for the adapter spec file
  adapter_spec_class_path = File.join(spec_dir, "#{Que.adapter.class.to_s.underscore}_spec.rb")

  # Exclude patterns for tests in the que/adapters directory
  config.exclude_pattern = "**/que/adapters/*.rb"

  # Require the adapter spec file if it exists
  if File.exist?(adapter_spec_class_path)
    require adapter_spec_class_path
  end

  config.before do
    QueJob.delete_all
    FakeJob.log = []
    ExceptionalJob.log = []
    ExceptionalJob::WithFailureHandler.log = []

    # In normal runtime we'll new-up metrics with consistent labels, but in tests we'll
    # create workers with all sorts of configurations. Ensure we clear the registry to
    # prevent mis-matched metric labels from raising exceptions from the incompatible
    # configurations.
    Prometheus::Client.registry.instance_eval { @metrics.clear }
  end
end

def with_workers(num, stop_timeout: 5, secondary_queues: [], &block)
  Que::WorkerGroup.start(
    num,
    wake_interval: 0.01,
    secondary_queues: secondary_queues,
  ).tap(&block).stop(stop_timeout)
end

# Wait for a maximum of [timeout] seconds for all jobs to be worked
def wait_for_jobs_to_be_worked(timeout: 10)
  start = Time.now
  loop do
    break if QueJob.count == 0 || Time.now - start > timeout

    sleep 0.1
  end
end
