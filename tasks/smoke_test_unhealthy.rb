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

# Replace the adapter so every work attempt raises PG::Error, simulating a
# persistent bad connection. Workers will always return :postgres_error,
# so the health check should always return 503.
class AlwaysFailingAdapter < Que::Adapters::Base
  def checkout
    raise PG::Error, "simulated persistent postgres error"
  end
end

Que.adapter = AlwaysFailingAdapter.new
