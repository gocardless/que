# frozen_string_literal: true

class ExceptionalJob < Que::Job
  @log = []

  class << self
    attr_accessor :log
  end

  class Error < StandardError; end

  def run(x)
    self.class.log << [:run, x]
    raise Error, "bad argument #{x}"
  end

  class WithFailureHandler < self
    @log = []

    def self.handle_job_failure(error, job)
      log << [:handle_job_failure, error, job]
    end
  end
end
