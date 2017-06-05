# frozen_string_literal: true

# Run tests a bunch of times, flush out thread race conditions / errors.
test_runs = ENV['TESTS'] ? ENV['TESTS'].to_i : 25

QUE_TEST_TIMEOUT = 10

%w( Gemfile spec/gemfiles/Gemfile2 ).each do |gemfile|
  # Install the particular gemfile
  system("BUNDLE_GEMFILE=#{gemfile} bundle")
  1.upto(test_runs) do |i|
    puts "Test Run #{i}"
    exit(-1) if !system("bundle exec rake")
  end
end
