# frozen_string_literal: true

source 'https://rubygems.org'

group :development, :test do
  gem 'rake'

  gem 'activerecord',    require: nil
  gem 'connection_pool', require: nil
  gem 'gc_ruboconfig'
  gem 'pg', require: nil, platform: :ruby
  gem 'pg_jruby', require: nil, platform: :jruby
  gem 'pond', require: nil
  gem 'rubocop'
  gem 'sequel', require: nil
end

group :test do
  gem 'pry'
  gem 'pry-byebug'
  gem 'rspec', '~> 3.9'
end

gem 'prometheus-client', '~> 1.0'
source "https://rubygems.pkg.github.com/gocardless" do
  gem "prometheus_gcstat", "0.1.1"
end
gemspec
