# frozen_string_literal: true

require 'spec_helper'
require 'connection_pool'

Kent.connection = KENT_SPEC_CONNECTION_POOL = ConnectionPool.new &NEW_PG_CONNECTION
KENT_ADAPTERS[:connection_pool] = Kent.adapter

describe "Kent using the ConnectionPool adapter" do
  before { Kent.adapter = KENT_ADAPTERS[:connection_pool] }

  it_behaves_like "a multi-threaded Kent adapter"

  it "should be able to tell when it's already in a transaction" do
    Kent.adapter.should_not be_in_transaction
    KENT_SPEC_CONNECTION_POOL.with do |conn|
      conn.async_exec "BEGIN"
      Kent.adapter.should be_in_transaction
      conn.async_exec "COMMIT"
    end
  end
end
