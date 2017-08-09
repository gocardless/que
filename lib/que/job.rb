require "active_support"
require "active_support/core_ext"

module Que
  class Job
    # These are order dependent, as we use them in prepared statements
    JOB_OPTIONS = %i[queue priority run_at job_class retryable].freeze

    # These are set in the class definition of the Job, as instance variables on the class
    def self.default_attrs
      {
        job_class: self.to_s,
        queue:     @queue,
        priority:  @priority,
        run_at:    @run_at&.call,
        retryable: true,
      }
    end

    def self.enqueue(*args, **kwargs)
      attrs = default_attrs.merge(kwargs.slice(*JOB_OPTIONS))
      possible_last_arg = kwargs.without(*JOB_OPTIONS)

      # If the job specifies a Hash as its last argument, make sure we include it (minus
      # the keys that might be job options)
      args.push(possible_last_arg) if possible_last_arg.any?

      # We return an instantiated Job class so that the caller can see the record that's
      # been inserted into the DB. In future, we might wish to change this, but for now
      # we'll keep it for compatibility.
      inserted_job =
        Que.execute(:insert_job, [*attrs.values_at(*JOB_OPTIONS), args]).first

      job = new(inserted_job)
      job.run_and_destroy(*inserted_job[:args]) if Que.mode == :sync
      job
    end

    def self.run(*args)
      new(args: args).tap { |job| job.run(*args) }
    end

    # This is accepting JOB_OPTIONS and args as keyword parameters. In future we want to
    # set instance variables instead of using a grab bag of parameters, which would allow
    # us to use required kwargs to provide some verification that the correct parameters
    # have been passed in.
    def initialize(attrs)
      @attrs = attrs
    end

    def run(*args)
      # In future, we want to raise NotImplementedError here to force subclasses to define
      # run. However Que's tests currently expect to be able to call Que::Job.run
    end

    def run_and_destroy(*args)
      run(*args)
      destroy
      true # required to keep API compatibility
    end
    alias _run run_and_destroy

    def destroy
      Que.execute(:destroy_job, @attrs.values_at(:queue, :priority, :run_at, :job_id))
    end
  end
end
