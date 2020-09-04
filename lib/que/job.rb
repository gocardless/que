# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"

module Que
  class Job
    # These are order dependent, as we use them in prepared statements
    JOB_OPTIONS = %i[queue priority run_at job_class retryable].freeze
    JOB_INSTANCE_FIELDS = %i[queue priority run_at job_id].freeze
    KWARGS_KEY = "__kwargs"

    # These are set in the class definition of the Job, as instance variables on the class
    def self.default_attrs
      {
        job_class: to_s,
        queue: @queue,
        priority: @priority,
        run_at: @run_at&.call,
        retryable: true,
      }
    end

    # Allow overriding of the default adapter when creating jobs. This enables people with
    # Que jobs from various database connections to coexist in the same project.
    def self.use_adapter(adapter)
      @adapter = adapter
    end

    def self.adapter
      @adapter || Que.adapter
    end

    def self.enqueue(
      *args,
      job_class: nil,
      queue: nil,
      priority: nil,
      run_at: nil,
      retryable: nil,
      **kwargs
    )
      attrs = {
        job_class: job_class || default_attrs[:job_class],
        queue:     queue     || default_attrs[:queue],
        priority:  priority  || default_attrs[:priority],
        run_at:    run_at    || default_attrs[:run_at],
        retryable: (retryable.nil? ? default_attrs[:retryable] : retryable),
      }

      args << { KWARGS_KEY => kwargs } if kwargs.any?

      # We return an instantiated Job class so that the caller can see the record that's
      # been inserted into the DB. In future, we might wish to change this, but for now
      # we'll keep it for compatibility.
      inserted_job =
        adapter.execute(:insert_job, [*attrs.values_at(*JOB_OPTIONS), args]).first

      job = new(inserted_job)
      # TODO: _run -> run_and_destroy(*inserted_job[:args])
      if Que.mode == :sync
        job._run
      else
        # We only want to log this if we're working the job async, as synchronous work
        # won't log the subsequent job_begin, job_worked events.
        Que.logger&.info(
          event: "que_job.job_enqueued",
          msg: "Job enqueued",
          que_job_id: job.attrs["job_id"],
          args: job.attrs["args"],
          **job.attrs.symbolize_keys.slice(*JOB_OPTIONS),
        )
      end
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
      @args = Array(attrs[:args])

      @kwargs = if @args.last.is_a?(Hash) && @args.last.keys == [KWARGS_KEY]
        @args.pop[KWARGS_KEY].symbolize_keys
      else
        {}
      end

      @stop = false
    end

    attr_reader :attrs

    def stop!
      @stop = true
    end

    def stop?
      @stop
    end

    def run(*args, **kwargs)
      # In future, we want to raise NotImplementedError here to force subclasses to define
      # run. However Que's tests currently expect to be able to call Que::Job.run
    end

    # TODO: Make sole run method (replace _run)
    def run_and_destroy(*args, **kwargs)
      run(*args, **kwargs)
      destroy
      true # required to keep API compatibility
    end

    # TODO: Remove this method
    #
    # _run was historically the method to override should you wish to extend Que. Various
    # gems such as que-failure build their implementation on this. We therefore have to
    # keep the _run method around until we update those gems to match the new API.
    def _run
      run_and_destroy(*@args, **@kwargs)
    end

    def destroy
      self.class.adapter.
        execute(:destroy_job, @attrs.values_at(:queue, :priority, :run_at, :job_id))
    end
  end
end
