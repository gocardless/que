# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "que/version"

Gem::Specification.new do |spec|
  spec.name          = "que"
  spec.version       = Que::VERSION
  spec.authors       = ["Chris Hanks"]
  spec.email         = ["christopher.m.hanks@gmail.com"]
  spec.description   =
    "A job queue that uses PostgreSQL's advisory locks for speed and reliability."
  spec.summary       = "A PostgreSQL-based Job Queue"
  spec.homepage      = "https://github.com/chanks/que"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.3"
  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = ["que"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport"
  spec.add_dependency "ostruct"
  spec.add_dependency "prometheus-client"
  spec.add_dependency "puma"
  spec.add_dependency "rack", ">= 2", "< 4"
  spec.add_dependency "rackup"

  spec.metadata["rubygems_mfa_required"] = "true"

  # This is a fork of the Original Que gem, so we don't want to push it to rubygems
  spec.metadata["allowed_push_host"] = ""
end
