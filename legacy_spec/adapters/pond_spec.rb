# frozen_string_literal: true

require 'spec_helper'
require 'pond'

Kent.connection = KENT_SPEC_POND = Pond.new &NEW_PG_CONNECTION
KENT_ADAPTERS[:pond] = Kent.adapter

describe "Kent using the Pond adapter" do
  before { Kent.adapter = KENT_ADAPTERS[:pond] }

  it_behaves_like "a multi-threaded Kent adapter"

  it "should be able to tell when it's already in a transaction" do
    Kent.adapter.should_not be_in_transaction
    KENT_SPEC_POND.checkout do |conn|
      conn.async_exec "BEGIN"
      Kent.adapter.should be_in_transaction
      conn.async_exec "COMMIT"
    end
  end
end
