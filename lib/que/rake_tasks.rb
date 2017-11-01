# frozen_string_literal: true

namespace :que do
  desc "Process Que's jobs using a worker pool"
  task :work => :environment do
    $stdout.sync = true

    $stdout.puts "The que:work rake task has been deprecated and will be removed in Que 1.0. Please transition to the que command line interface instead."

    if defined?(::Rails) && Rails.respond_to?(:application)
      # ActiveSupport's dependency autoloading isn't threadsafe, and Que uses
      # multiple threads, which means that eager loading is necessary. Rails
      # explicitly prevents eager loading when the environment task is invoked,
      # so we need to manually eager load the app here.
      Rails.application.eager_load!
    end

    Que.logger.level  = Logger.const_get((ENV['QUE_LOG_LEVEL'] || 'INFO').upcase)
    Que.mode          = :async

    worker = Que::Worker.new(
      queue: ENV['QUE_QUEUE'],
      wake_interval: ENV['QUE_WAKE_INTERVAL'],
    )

    # When changing how signals are caught, be sure to test the behavior with
    # the rake task in tasks/safe_shutdown.rb.

    %w( INT TERM ).each do |signal|
      trap(signal) { worker.stop! }
    end

    worker.work_loop

    loop do
      sleep 0.01
      break if stop
    end
  end

  desc "Migrate Que's job table to the most recent version (creating it if it doesn't exist)"
  task :migrate => :environment do
    Que.migrate!
  end

  desc "Drop Que's job table"
  task :drop => :environment do
    Que.drop!
  end

  desc "Clear Que's job table"
  task :clear => :environment do
    Que.clear!
  end
end
