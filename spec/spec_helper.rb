$LOAD_PATH << File.expand_path(__FILE__, '../lib')

require 'que'
require 'rspec'
require 'active_record'
require_relative "./fake_job"

ActiveRecord::Base.establish_connection(
  adapter: 'postgresql',
  host: ENV.fetch('PGHOST', 'localhost'),
  user: ENV.fetch('PGUSER', 'postgres'),
  password: ENV.fetch('PGPASSWORD', ''),
  database: ENV.fetch('PGDATABASE', 'que-test')
)

# Make sure our test database is prepared to run Que
Que.connection  = ActiveRecord
Que.migrate!

class QueJob < ActiveRecord::Base
  self.primary_key = 'job_id'
end

RSpec.configure do |config|
  config.before(:each) { QueJob.delete_all }
end
