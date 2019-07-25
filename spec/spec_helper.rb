# frozen_string_literal: true

$LOAD_PATH << File.expand_path(__FILE__, "../lib")

require "que"
require "rspec"
require "active_record"

require_relative "./helpers/create_user"
require_relative "./helpers/exceptional_job"
require_relative "./helpers/fake_job"
require_relative "./helpers/que_job"
require_relative "./helpers/sleep_job"
require_relative "./helpers/interruptible_sleep_job"
require_relative "./helpers/user"

def postgres_now
  now = ActiveRecord::Base.connection.execute("SELECT NOW();")[0]["now"]
  Time.parse(now)
end

def establish_database_connection
  ActiveRecord::Base.establish_connection(
    adapter: "postgresql",
    host: ENV.fetch("PGHOST", "localhost"),
    user: ENV.fetch("PGUSER", "postgres"),
    password: ENV.fetch("PGPASSWORD", ""),
    database: ENV.fetch("PGDATABASE", "que-test"),
  )
end

establish_database_connection

# Make sure our test database is prepared to run Que
Que.connection = ActiveRecord
Que.migrate!

# Ensure we have a logger, so that we can test the code paths that log
Que.logger = Logger.new("/dev/null")

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
end
