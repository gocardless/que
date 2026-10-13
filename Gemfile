# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'benchmark'
  gem 'rake'

  gem 'activerecord',    require: nil
  gem 'connection_pool', require: nil
  gem 'gc_ruboconfig', '>= 6'
  gem 'multi_json', '~> 1.21', require: nil
  gem 'pg', require: nil, platform: :ruby
  gem 'pg_jruby', require: nil, platform: :jruby
  gem 'pond', require: nil
  gem 'rubocop', '~> 1.92.0'
  gem 'rubocop-performance', '~> 1.27.0'
  gem 'rubocop-rake', '~> 0.7.1'
  gem 'rubocop-rspec', '~> 3.10.0'
  gem 'rubocop-sequel', '~> 0.4.1', require: false
  gem 'sequel', require: nil

  rack_version = ENV.fetch('RACK_VERSION', "3.2.7")
  gem "rack", rack_version
  if Gem::Version.new(rack_version) < Gem::Version.new('3.0.0')
    gem "rackup", "~> 1.0"
  else
    gem "rackup", "~> 2.0"
  end
end

group :test do
  gem 'pry'
  gem 'pry-byebug'
  gem 'rspec', '~> 3.9'
end
