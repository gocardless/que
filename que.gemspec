# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "que/version"

Gem::Specification.new do |spec|
  spec.name          = "que"
  spec.version       = Que::Version
  spec.authors       = ["Chris Hanks"]
  spec.email         = ["christopher.m.hanks@gmail.com"]
  spec.description   =
    "A job queue that uses PostgreSQL's advisory locks for speed and reliability."
  spec.summary       = "A PostgreSQL-based Job Queue"
  spec.homepage      = "https://github.com/chanks/que"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = ["que"]
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "prometheus-client", "~> 1.0"
  spec.add_dependency "rack", "~> 2.0"
  spec.add_development_dependency "bundler", "~> 1.3"

  spec.add_runtime_dependency "activesupport"
end
