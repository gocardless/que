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
  establish_connection(
      adapter: "postgresql",
      host: ENV.fetch("LOCK_PGHOST", "localhost"),
      user: ENV.fetch("LOCK_PGUSER", "ubuntu"),
      password: ENV.fetch("LOCK_PGPASSWORD", "password"),
      database: ENV.fetch("LOCK_PGDATABASE", "lock-test"),
      port: ENV.fetch("LOCK_PGPORT", 5435),
      pool: 6,)
end

class YugabyteRecord < ActiveRecord::Base
    establish_connection(
      adapter: "postgresql",
      host: ENV.fetch("PGHOST", "localhost"),
      user: ENV.fetch("PGUSER", "ubuntu"),
      password: ENV.fetch("PGPASSWORD", "password"),
      database: ENV.fetch("PGDATABASE", "que-test"),
    )
end

# Make sure our test database is prepared to run Que
if ENV['YUGABYTE_QUE_WORKER_ENABLED']
  Que.connection = Que::Adapters::ActiveRecordWithLock.new(
                job_connection_pool: YugabyteRecord.connection_pool,
                lock_connection_pool: LockDatabaseRecord.connection_pool,
  )
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
  if  ENV['YUGABYTE_QUE_WORKER_ENABLED']
    config.before(:all) do
      Que.adapter.checkout_lock_database_connection
    end
    config.after(:all) do
      LockDatabaseRecord.connection_pool.disconnect!
    end
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
