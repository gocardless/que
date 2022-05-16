#!/usr/bin/env ruby
# frozen_string_literal: true

require "kent"
require "json"
require "active_record"

ActiveRecord::Base.establish_connection(adapter: "postgresql", dbname: "kent-benchmark")
Kent.connection = ActiveRecord
Kent.migrate!

Kent.logger = Logger.new(STDOUT)
Kent.logger.formatter = proc do |severity, datetime, _progname, payload|
  { ts: datetime, tid: Thread.current.object_id, level: severity }.
    merge(payload).to_json + "\n"
end

class KentJob < ActiveRecord::Base
  self.primary_key = "job_id"
end

module Jobs
  class Sleep < Kent::Job
    def run(interval)
      sleep(interval)
    end
  end
end
