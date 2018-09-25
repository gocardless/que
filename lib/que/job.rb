# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"

module Que
  class Job
    # These are order dependent, as we use them in prepared statements
    JOB_OPTIONS = %i[queue priority run_at job_class retryable].freeze
    JOB_INSTANCE_FIELDS = %i[queue priority run_at job_id].freeze

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
      attrs, args = extract_attrs_and_args(*args, **kwargs)

      # We return an instantiated Job class so that the caller can see the record that's
      # been inserted into the DB. In future, we might wish to change this, but for now
      # we'll keep it for compatibility.
      inserted_job =
        Que.execute(SQL[:insert_job], [attrs.merge(args: args.to_json)]).first

      job = new(inserted_job)
      # TODO: _run -> run_and_destroy(*inserted_job[:args])
      job._run if Que.mode == :sync
      job
    end

    # This method extracts the given args and attrs from parameters supplied to enqueue,
    # separating out things like `run_at` and genuine keyword args to a job.
    def self.extract_attrs_and_args(*args, **kwargs)
      attrs = default_attrs.merge(kwargs.slice(*JOB_OPTIONS))
      possible_last_arg = kwargs.without(*JOB_OPTIONS)

      # If the job specifies a Hash as its last argument, make sure we include it (minus
      # the keys that might be job options)
      args = [*args, possible_last_arg] if possible_last_arg.any?

      return attrs, args
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

    attr_reader :attrs

    def run(*args)
      # In future, we want to raise NotImplementedError here to force subclasses to define
      # run. However Que's tests currently expect to be able to call Que::Job.run
    end

    # TODO: Make sole run method (replace _run)
    def run_and_destroy(*args)
      run(*args)
      destroy
      true # required to keep API compatibility
    end

    # TODO: Remove this method
    #
    # _run was historically the method to override should you wish to extend Que. Various
    # gems such as que-failure build their implementation on this. We therefore have to
    # keep the _run method around until we update those gems to match the new API.
    def _run
      run_and_destroy(*@attrs[:args])
    end

    def destroy
      Que.execute(SQL[:destroy_job], [@attrs.slice(:queue, :priority, :run_at, :job_id)])
    end
  end
end
