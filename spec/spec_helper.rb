$LOAD_PATH << File.expand_path(__FILE__, '../lib')

require 'que'
require 'rspec'
require 'active_record'
require 'pry'
require 'thread'

require_relative "./helpers/que_job"
require_relative "./helpers/fake_job"
require_relative "./helpers/exceptional_job"
require_relative "./helpers/user"
require_relative "./helpers/create_user"

def postgres_now
  now = ActiveRecord::Base.connection.execute("SELECT NOW();")[0]["now"]
  Time.parse(now)
end

def establish_database_connection
  ActiveRecord::Base.establish_connection(
    adapter: 'postgresql',
    host: ENV.fetch('PGHOST', 'localhost'),
    user: ENV.fetch('PGUSER', 'postgres'),
    password: ENV.fetch('PGPASSWORD', ''),
    database: ENV.fetch('PGDATABASE', 'que-test')
  )
end

establish_database_connection

# Make sure our test database is prepared to run Que
Que.connection = ActiveRecord
Que.migrate!

class SpecLogger < Logger
  def add(severity, progname, message = nil)
    entries << message
  end

  def entries
    @entries ||= Queue.new
  end
end

Que.logger = SpecLogger.new(STDOUT)

RSpec.configure do |config|
  config.before(:each) do
    QueJob.delete_all
    # Collect log entries over the course of a spec
    Que.logger.entries.clear

    FakeJob.log = []
    ExceptionalJob.log = []
    ExceptionalJob::WithFailureHandler.log = []
  end

  config.after(:each) do
    puts Que.logger.entries
  end
end
