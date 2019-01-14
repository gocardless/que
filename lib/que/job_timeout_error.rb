# frozen_string_literal: true

module Que
  # This exception is raised whenever a worker has exceeded the grace period allowed to
  # terminate, and often precedes an incoming SIGKILL. It inherits from Interrupt to avoid
  # bare rescues (or those that catch StandardError) from catching the error, instead
  # being caught only by rescues that are absolutely sure they want to catch it.
  class JobTimeoutError < RuntimeError; end
end
