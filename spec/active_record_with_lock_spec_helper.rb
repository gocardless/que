# frozen_string_literal: true

class LockDatabaseRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :lock, reading: :lock }
end

class JobRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :default, reading: :default }
end

def active_record_with_lock_adapter_connection
  Que::Adapters::ActiveRecordWithLock.new(
    job_connection_pool: JobRecord.connection_pool,
    lock_connection_pool: LockDatabaseRecord.connection_pool,
  )
end
