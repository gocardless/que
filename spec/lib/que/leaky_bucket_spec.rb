# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::LeakyBucket do
  subject(:bucket) { described_class.new(window: window, budget: budget, clock: clock) }

  let(:window) { 5.0 }
  let(:budget) { 1.0 }
  let(:clock)  { fake_clock.new }

  # Provide a test clock interface, allowing the observations and sleeps made by the
  # bucket to advance test time.
  let(:fake_clock) do
    Class.new do
      def initialize
        @now = 0.0
      end

      attr_reader :now

      def sleep(duration)
        @now += duration
      end

      def advance(duration)
        @now += duration
      end
    end
  end

  def measure_total_work(clock, bucket, runtime:, work_duration: 0.05, error: false)
    total_work = 0.0
    until clock.now > runtime
      bucket.refill
      begin
        bucket.observe do
          duration = Random.rand(work_duration)
          clock.advance(duration)
          total_work += duration
          raise StandardError, "throwing" if error
        end
      rescue StandardError => e
        raise(e) unless error
      end
    end

    total_work
  end

  context "when working as much as possible" do
    subject do
      measure_total_work(clock, bucket, runtime: 10.0, error: throw_error)
    end

    let(:throw_error) { false }

    context "runtime 10s, window 10s, budget 2s" do
      let(:runtime) { 10.0 }
      let(:window) { 10.0 }
      let(:budget) { 2.0 }

      it { is_expected.to be_within(0.2).of(2.0) }

      context "when observed method throws exception" do
        let(:throw_error) { true }

        it { is_expected.to be_within(0.2).of(2.0) }
      end
    end

    context "runtime 10s, window 5s, budget 4s" do
      let(:runtime) { 10.0 }
      let(:window) { 5.0 }
      let(:budget) { 4.0 }

      it { is_expected.to be_within(0.2).of(8.0) }
    end
  end
end
