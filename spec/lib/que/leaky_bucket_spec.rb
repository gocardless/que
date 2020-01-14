# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::LeakyBucket do
  subject(:bucket) { described_class.new(window: window, budget: budget, clock: clock) }

  let(:window) { 5.0 }
  let(:budget) { 1.0 }
  let(:clock)  { FakeClock.new }

  # Provide a test clock interface, allowing the observations and sleeps made by the
  # bucket to advance test time.
  FakeClock = Class.new do
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

  def measure_total_work(clock, bucket, runtime:, work_duration: 0.05)
    total_work = 0.0
    until clock.now > runtime
      bucket.refill
      bucket.observe do
        duration = Random.rand(work_duration)
        clock.advance(duration)
        total_work += duration
      end
    end

    total_work
  end

  context "when working as much as possible" do
    subject do
      measure_total_work(clock, bucket, runtime: 10.0)
    end

    context "runtime 10s, window 10s, budget 2s" do
      let(:runtime) { 10.0 }
      let(:window) { 10.0 }
      let(:budget) { 2.0 }

      it { is_expected.to be_within(0.2).of(2.0) }
    end

    context "runtime 10s, window 5s, budget 4s" do
      let(:runtime) { 10.0 }
      let(:window) { 5.0 }
      let(:budget) { 4.0 }

      it { is_expected.to be_within(0.2).of(8.0) }
    end
  end
end
