# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "kent/version"

Gem::Specification.new do |spec|
  spec.name          = "kent"
  spec.version       = Kent::Version
  spec.authors       = ["Chris Hanks"]
  spec.email         = ["christopher.m.hanks@gmail.com", "developers@gocardless.com"]
  spec.description   =
    "A job queue that uses PostgreSQL's advisory locks for speed and reliability. Fork of que"
  spec.summary       = "A PostgreSQL-based Job Queue"
  spec.homepage      = "https://github.com/gocardless/kent"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = ["kent"]
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  # We're pointing to our own branch of the Prometheus Client.
  # Ideally we'd do this in the `gemspec`, but you can't do that.
  # Instead, we remove the version restriction from `gemspec` and add it to the `Gemfile`
  # instead, and in any other clients of `Kent`.
  # This is highly non ideal, but unless we properly fork, we have to do this for now.
  spec.add_dependency "prometheus-client"

  spec.add_dependency "rack", "~> 2.0"
  spec.add_dependency "webrick", "~> 1.7"

  spec.add_runtime_dependency "activesupport"
end
