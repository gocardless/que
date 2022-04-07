# frozen_string_literal: true

class FakeJobWithCustomLogs < FakeJob
  custom_log_context ->(job) {
    {
      custom_log_1: job.attrs[:args][0],
      custom_log_2: "test-log",
    }
  }

  @log = []
end
