# frozen_string_literal: true

class LockDatabaseRecord < ActiveRecord::Base
  establish_connection(
    adapter: "postgresql",
    host: ENV.fetch("LOCK_PGHOST", "localhost"),
    user: ENV.fetch("LOCK_PGUSER", "postgres"),
    password: ENV.fetch("LOCK_PGPASSWORD", "password"),
    database: ENV.fetch("LOCK_PGDATABASE", "lock-test"),
    port: ENV.fetch("LOCK_PGPORT", 5434),
    pool: 5,
  )
end

class JobRecord < ActiveRecord::Base
  establish_connection(
    adapter: "postgresql",
    host: ENV.fetch("PGHOST", "localhost"),
    user: ENV.fetch("PGUSER", "ubuntu"),
    password: ENV.fetch("PGPASSWORD", "password"),
    database: ENV.fetch("PGDATABASE", "que-test"),
  )
end

def active_record_with_lock_adapter_connection
  Que::Adapters::ActiveRecordWithLock.new(
    job_connection_pool: JobRecord.connection_pool,
    lock_connection_pool: LockDatabaseRecord.connection_pool,
  )
end
