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
require_relative "../lib/que/adapters/yugabyte"

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

class LockDatabaseRecord < ActiveRecord::Base
  def self.establish_lock_database_connection
    establish_connection(
      adapter: "postgresql",
      host: ENV.fetch("LOCK_PGHOST", "localhost"),
      user: ENV.fetch("LOCK_PGUSER", "ubuntu"),
      password: ENV.fetch("LOCK_PGPASSWORD", "password"),
      database: ENV.fetch("LOCK_PGDATABASE", "lock-test"),
      port: ENV.fetch("LOCK_PGPORT", 5434),
    )
  end
  def self.connection
    establish_lock_database_connection.connection
  end
end

class YugabyteRecord < ActiveRecord::Base
  def self.establish_lock_database_connection
    establish_connection(
      adapter: "postgresql",
      host: ENV.fetch("PGHOST", "localhost"),
      user: ENV.fetch("PGUSER", "ubuntu"),
      password: ENV.fetch("PGPASSWORD", "password"),
      database: ENV.fetch("PGDATABASE", "que-test"),
    )
  end
  def self.connection
    establish_lock_database_connection.connection
  end
end

# Make sure our test database is prepared to run Que
if ENV['YUGABYTE_QUE_WORKER_ENABLED']
  Que.connection = Que::Adapters::Yugabyte
else
  Que.connection = ActiveRecord
end

Que.migrate!

# Ensure we have a logger, so that we can test the code paths that log
Que.logger = Logger.new("/dev/null")


RSpec.configure do |config|
  # config.before(:each, :with_yugabyte_adapter) do
  #   Que.adapter.cleanup!
  #   Que.connection = Que::Adapters::Yugabyte
  # end
  
  # config.after(:each, :with_yugabyte_adapter) do
  #   Que.adapter.cleanup!
  #   Que.connection = ActiveRecord
  # end
  config.filter_run_when_matching :conditional_test if ENV['YUGABYTE_QUE_WORKER_ENABLED']

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
