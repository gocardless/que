# frozen_string_literal: true

require 'spec_helper'

describe Kent, 'helpers' do
  it "should be able to clear the jobs table" do
    DB[:kent_jobs].insert :job_class => "Kent::Job"
    DB[:kent_jobs].count.should be 1
    Kent.clear!
    DB[:kent_jobs].count.should be 0
  end
end
