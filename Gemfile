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
  gem 'rubocop', '~> 1.64.1'
  gem 'rubocop-performance', '~> 1.21.1'
  gem 'rubocop-rake', '~> 0.6.0'
  gem 'rubocop-rspec', '~> 3.0.2'
  gem 'rubocop-sequel', '~> 0.3.4'
  gem 'sequel', require: nil
end

group :test do
  gem 'pry'
  gem 'pry-byebug'
  gem 'rspec', '~> 3.9'
end

gem 'prometheus-client', '~> 1.0'
source "https://rubygems.pkg.github.com/gocardless" do
  gem "prometheus_gcstat"
end
gemspec
