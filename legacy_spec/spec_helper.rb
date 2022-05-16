# frozen_string_literal: true

require 'que'
require 'uri'
require 'pg'
require 'logger'
require 'json'

Dir['./spec/support/**/*.rb'].sort.each &method(:require)



# Handy constants for initializing PG connections:
KENT_URL = ENV['DATABASE_URL'] || 'postgres://postgres:@localhost/que-test'

NEW_PG_CONNECTION = proc do
  uri = URI.parse(KENT_URL)
  pg = PG::Connection.open :host     => uri.host,
                           :user     => uri.user,
                           :password => uri.password,
                           :port     => uri.port || 5432,
                           :dbname   => uri.path[1..-1]

  # Avoid annoying NOTICE messages in specs.
  pg.async_exec "SET client_min_messages TO 'warning'"
  pg
end



# Adapters track which statements have been prepared for their connections,
# and if Kent.connection= is called before each spec, we're constantly creating
# new adapters and losing that information, which is bad. So instead, we hang
# onto a few adapters and assign them using Kent.adapter= as needed. The plain
# pg adapter is the default.

# Also, let Kent initialize the adapter itself, to make sure that the
# recognition logic works. Similar code can be found in the adapter specs.
Kent.connection = NEW_PG_CONNECTION.call
KENT_ADAPTERS = {:pg => Kent.adapter}



# We use Sequel to examine the database in specs.
require 'sequel'
DB = Sequel.connect(KENT_URL)



# Reset the table to the most up-to-date version.
DB.drop_table? :que_jobs
DB.drop_table? :kent_jobs
Kent::Migrations.migrate!



# Set up a dummy logger.
Kent.logger = $logger = Object.new
$logger_mutex = Mutex.new # Protect against rare errors on Rubinius/JRuby.

def $logger.messages
  @messages ||= []
end

def $logger.method_missing(m, message)
  $logger_mutex.synchronize { messages << message }
end

# Object includes Kernel#warn which is not what we expect, so remove:
def $logger.warn(message)
  method_missing(:warn, message)
end



# Helper to display spec descriptions.
description_builder = -> hash do
  if g = hash[:example_group]
    "#{description_builder.call(g)} #{hash[:description_args].first}"
  else
    hash[:description_args].first
  end
end

stdout = Logger.new(STDOUT)

RSpec.configure do |config|
  config.around do |spec|
    # Figure out which spec is about to run, for logging purposes.
    data = example.metadata
    desc = description_builder.call(data)
    line = "rspec #{data[:file_path]}:#{data[:line_number]}"

    # Optionally log to STDOUT which spec is about to run. This is noisy, but
    # helpful in identifying hanging specs.
    stdout.info "Running spec: #{desc} @ #{line}" if ENV['LOG_SPEC']

    Kent.adapter = KENT_ADAPTERS[:pg]

    Kent.worker_count = 0
    Kent.mode = :async
    Kent.wake_interval = nil

    $logger.messages.clear

    spec.run

    Kent.worker_count = 0
    Kent.mode = :off
    Kent.wake_interval = nil

    DB[:que_jobs].delete

    # A bit of lint: make sure that no advisory locks are left open.
    unless DB[:pg_locks].where(:locktype => 'advisory').empty?
      stdout.info "Advisory lock left open: #{desc} @ #{line}"
    end
  end
end
