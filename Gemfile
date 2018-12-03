source 'https://rubygems.org'

group :development, :test do
  gem 'rake'

  gem 'activerecord',    :require => nil
  gem 'sequel',          :require => nil
  gem 'connection_pool', :require => nil
  gem 'pond',            :require => nil
  gem 'pg',              :require => nil, :platform => :ruby
  gem 'pg_jruby',        :require => nil, :platform => :jruby
end

group :test do
  gem 'rspec', '~> 2.14.1'
  gem 'pry'
  gem 'pry-byebug'
end

platforms :rbx do
  gem 'rubysl', '~> 2.0'
  gem 'json', '~> 1.8'
end

gem 'prometheus-client',
    git: 'https://github.com/gocardless/prometheus_client_ruby.git',
    branch: 'gc_production_branch_do_not_push'

gemspec
