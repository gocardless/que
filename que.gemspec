# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'que/version'

Gem::Specification.new do |spec|
  spec.name          = 'que'
  spec.version       = Que::Version
  spec.authors       = ["Chris Hanks"]
  spec.email         = ['christopher.m.hanks@gmail.com']
  spec.description   = %q{A job queue that uses PostgreSQL's advisory locks for speed and reliability.}
  spec.summary       = %q{A PostgreSQL-based Job Queue}
  spec.homepage      = 'https://github.com/chanks/que'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($/)
  spec.executables   = ['que']
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  # We're pointing to our own branch of the Prometheus Client.
  # Ideally we'd do this in the `gemspec`, but you can't do that.
  # Instead, we remove the version restriction from `gemspec` and add it to the `Gemfile`
  # instead, and in any other clients of `Que`.
  # This is highly non ideal, but unless we properly fork, we have to do this for now.
  spec.add_dependency 'prometheus-client'

  spec.add_dependency 'rack', '~> 2.0'
  spec.add_development_dependency 'bundler', '~> 1.3'

  spec.add_runtime_dependency 'activesupport'
end
