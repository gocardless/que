# frozen_string_literal: true

# This task is used to test Kent's behavior when its process is shut down.

# The situation we're trying to avoid occurs when the process dies while a job
# is in the middle of a transaction - ideally, the transaction would be rolled
# back and the job could just be reattempted later, but if we're not careful,
# the transaction could be committed prematurely. For specifics, see here:

# http://coderrr.wordpress.com/2011/05/03/beware-of-threadkill-or-your-activerecord-transactions-are-in-danger-of-being-partially-committed/

# So, this task opens a transaction within a job, makes a write, then prompts
# you to kill it with one of a few signals. You can then run it again to make
# sure that the write was rolled back (if it wasn't, Kent isn't functioning
# like it should). This task only explicitly tests Sequel, but the behavior
# for ActiveRecord is very similar.

# rubocop:disable Style/GlobalVars
task :safe_shutdown do
  require "sequel"
  require "kent"

  url = ENV["DATABASE_URL"] || "postgres://postgres:@localhost/que-test"
  DB = Sequel.connect(url)

  if DB.table_exists?(:kent_jobs)
    puts "Uh-oh! Previous shutdown wasn't clean!" if DB[:kent_jobs].where(job_id: 0).exists
    DB.drop_table :kent_jobs
  end

  Kent.connection = DB
  Kent.create!

  $queue = Queue.new

  class SafeJob < Kent::Job
    def run
      DB.transaction do
        DB[:kent_jobs].insert(job_id: 0, job_class: "Kent::Job")
        $queue.push nil
        sleep
      end
    end
  end

  SafeJob.enqueue
  Kent.mode = :async
  $queue.pop

  puts "From a different terminal window, run one of the following:"
  %w[SIGINT SIGTERM SIGKILL].each do |signal|
    puts "kill -#{signal} #{Process.pid}"
  end

  stop = false
  trap("INT") { stop = true }

  at_exit do
    $stdout.puts "Finishing Kent's current jobs before exiting..."
    Kent.mode = :off
    $stdout.puts "Kent's jobs finished, exiting..."
  end

  loop do
    sleep 0.01
    break if stop
  end
end
# rubocop:enable Style/GlobalVars
