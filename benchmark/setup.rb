#!/usr/bin/env ruby
# frozen_string_literal: true

require "que"
require "json"
require "active_record"

ActiveRecord::Base.establish_connection(adapter: "postgresql", dbname: "que-benchmark")
Que.connection = ActiveRecord
Que.migrate!

Que.logger = Logger.new(STDOUT)
Que.logger.formatter = proc do |severity, datetime, _progname, payload|
  { ts: datetime, tid: Thread.current.object_id, level: severity }.
    merge(payload).to_json + "\n"
end

class QueJob < ActiveRecord::Base
  self.primary_key = "job_id"
end

module Jobs
  class Sleep < Que::Job
    def run(interval)
      sleep(interval)
    end
  end
end
