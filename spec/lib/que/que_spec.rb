# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que do
  describe ".connection=" do
    it "accepts a custom Adapters::Base subclass instance and sets it as the adapter" do
      custom_adapter_class = Class.new(Que::Adapters::Base)
      stub_const("MyApp::CustomAdapter", custom_adapter_class)
      custom_adapter = MyApp::CustomAdapter.new

      expect { described_class.connection = custom_adapter }.to_not raise_error
      expect(described_class.adapter).to eq(custom_adapter)
    end

    it "raises for an unrecognized non-adapter object" do
      expect { described_class.connection = Object.new }.
        to raise_error(/Que connection not recognized/)
    end

    # Named connection-class branches must take priority over the is_a?(Adapters::Base)
    # fallback. Without this ordering, a Base subclass whose class name happens to match
    # a known connection type would be passed through as-is instead of being wrapped by
    # the appropriate adapter.
    context "when a connection object is both a known named type and an Adapters::Base subclass" do
      it "wraps it via the named-type branch rather than passing it through as-is" do
        # Simulate the collision: a class named "ConnectionPool" that also inherits Base.
        # ConnectionPool adapter is used because its constructor only stores @pool and
        # does not interact with the connection object at initialisation time.
        klass = Class.new(Que::Adapters::Base)
        stub_const("ConnectionPool", klass)
        connection = ConnectionPool.new

        described_class.connection = connection

        expect(described_class.adapter).to be_a(Que::Adapters::ConnectionPool)
        expect(described_class.adapter).to_not equal(connection)
      end
    end
  end
end
