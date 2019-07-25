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
  gem 'rspec', '~> 2.14.1'
end

platforms :rbx do
  gem 'json', '~> 1.8'
  gem 'rubysl', '~> 2.0'
end

gem 'prometheus-client', '~> 0.10.0.alpha'
gem 'prometheus_gcstat', git: 'git@github.com:gocardless/prometheus_gcstat_ruby'

gemspec
