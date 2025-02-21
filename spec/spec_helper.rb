# frozen_string_literal: true

$LOAD_PATH << File.expand_path(__FILE__, "../lib")

require "que"
require "rspec"
require "active_record"

ActiveRecord::Base.configurations = {
  "default" => {
    adapter: "postgresql",
    host: ENV.fetch("PGHOST", "localhost"),
    user: ENV.fetch("PGUSER", "postgres"),
    password: ENV.fetch("PGPASSWORD", "password"),
    database: ENV.fetch("PGDATABASE", "que-test"),
    port: ENV.fetch("PGPORT", 5435),
  },
  "lock" => {
    adapter: "postgresql",
    host: ENV.fetch("LOCK_PGHOST", "localhost"),
    user: ENV.fetch("LOCK_PGUSER", "postgres"),
    password: ENV.fetch("LOCK_PGPASSWORD", "password"),
    database: ENV.fetch("LOCK_PGDATABASE", "que-test-lock"),
    port: ENV.fetch("LOCK_PGPORT", 5436),
    pool: 5,
  },
}

ActiveRecord::Base.configurations.configs_for(env_name: "default").each do |config|
  ActiveRecord::Base.establish_connection(config)
end

ActiveRecord::Base.configurations.configs_for(env_name: "lock").each do |config|
  ActiveRecord::Base.establish_connection(config)
end

ActiveRecord::Base.connects_to(database: { writing: :default, reading: :default })

require_relative "helpers/create_user"
require_relative "helpers/exceptional_job"
require_relative "helpers/fake_job"
require_relative "helpers/que_job"
require_relative "helpers/sleep_job"
require_relative "helpers/interruptible_sleep_job"
require_relative "helpers/user"
require_relative "active_record_with_lock_spec_helper"

# Make sure our test database is prepared to run Que
Que.connection = ActiveRecord
default_adapter = Que.adapter

Que.migrate!

# Ensure we have a logger, so that we can test the code paths that log
Que.logger = Logger.new(File::NULL)

RSpec.configure do |config|
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

  config.before do |example|
    Que.adapter = if example.metadata[:active_record_with_lock]
                    active_record_with_lock_adapter_connection
                  else
                    default_adapter
                  end
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

def postgres_now
  ActiveRecord::Base.connection.execute("SELECT NOW();")[0]["now"]
end
