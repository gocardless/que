# frozen_string_literal: true

require "active_record"
require_relative "../lib/que"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  host: ENV.fetch("PGHOST", "localhost"),
  user: ENV.fetch("PGUSER", "postgres"),
  password: ENV.fetch("PGPASSWORD", ""),
  database: ENV.fetch("PGDATABASE", "que-test"),
)

Que.connection = ActiveRecord
Que.migrate!
