# frozen_string_literal: true

require 'spec_helper'

describe Kent do
  it ".connection= with an unsupported connection should raise an error" do
    proc{Kent.connection = "ferret"}.should raise_error RuntimeError, /Kent connection not recognized: "ferret"/
  end

  it ".adapter when no connection has been established should raise an error" do
    Kent.connection = nil
    proc{Kent.adapter}.should raise_error RuntimeError, /Kent connection not established!/
  end
end
