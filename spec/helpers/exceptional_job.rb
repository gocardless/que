# frozen_string_literal: true

class ExceptionalJob < Kent::Job
  @log = []

  class << self
    attr_accessor :log
  end

  class Error < StandardError; end

  def run(arg)
    self.class.log << [:run, arg]
    raise Error, "bad argument #{arg}"
  end

  class WithFailureHandler < self
    @log = []

    def self.handle_job_failure(error, job)
      log << [:handle_job_failure, error, job]
    end
  end
end
