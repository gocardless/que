# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'rake'

  gem 'activerecord',    require: nil
  gem 'connection_pool', require: nil
  gem 'gc_ruboconfig'
  gem 'pg', require: nil, platform: :ruby
  gem 'pg_jruby', require: nil, platform: :jruby
  gem 'pond', require: nil
  gem 'rubocop', '~> 1.72.2'
  gem 'rubocop-performance', '~> 1.24.0'
  gem 'rubocop-rake', '~> 0.7.1'
  gem 'rubocop-rspec', '~> 3.5.0'
  gem 'rubocop-sequel', '~> 0.3.8'
  gem 'sequel', require: nil

  rack_version = ENV.fetch('RACK_VERSION', "3.1")
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
