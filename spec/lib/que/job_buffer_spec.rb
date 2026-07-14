# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::JobBuffer do
  subject(:buffer) { described_class.new(maximum_size: maximum_size) }

  let(:maximum_size) { 2 }

  def job(job_id, priority: 1, run_at: Time.now)
    { queue: "default", priority: priority, run_at: run_at, job_id: job_id }
  end

  describe "#push" do
    it "accepts jobs up to the maximum size" do
      rejected = buffer.push(job(1), job(2))
      expect(rejected).to eq([])
      expect(buffer.size).to eq(2)
    end

    it "rejects jobs that don't fit, returning them to the caller" do
      accepted_job = job(1)
      rejected_job = job(2)

      buffer.push(job(0), accepted_job)
      rejected = buffer.push(rejected_job)

      expect(rejected).to eq([rejected_job])
      expect(buffer.size).to eq(2)
    end

    it "orders jobs by priority, then run_at, then job_id" do
      low = job(3, priority: 10)
      high = job(1, priority: 1)

      buffer.push(low)
      buffer.push(high)

      expect(buffer.shift).to eq(high)
      expect(buffer.shift).to eq(low)
    end

    it "returns jobs unchanged once the buffer is stopping" do
      buffer.stop
      jobs = [job(1), job(2)]
      expect(buffer.push(*jobs)).to eq(jobs)
      expect(buffer.size).to eq(0)
    end
  end

  describe "#shift" do
    it "returns a pushed job immediately" do
      pushed_job = job(1)
      buffer.push(pushed_job)
      expect(buffer.shift).to eq(pushed_job)
    end

    it "blocks until a job is pushed" do
      result = nil
      thread = Thread.new { result = buffer.shift }

      sleep 0.05
      expect(result).to be_nil

      pushed_job = job(1)
      buffer.push(pushed_job)
      thread.join(1)

      expect(result).to eq(pushed_job)
    end

    it "returns false for all waiters once stopped" do
      threads = Array.new(3) { Thread.new { buffer.shift } }
      sleep 0.05

      buffer.stop

      results = threads.map { |t| t.join(1).value }
      expect(results).to all(eq(false))
    end
  end

  describe "#available_capacity" do
    it "reflects free slots" do
      expect(buffer.available_capacity).to eq(2)
      buffer.push(job(1))
      expect(buffer.available_capacity).to eq(1)
      buffer.shift
      expect(buffer.available_capacity).to eq(2)
    end
  end

  describe "#wait_for_space" do
    it "returns immediately if space is already available" do
      expect { buffer.wait_for_space(5) }.to take_less_than(1)
    end

    it "blocks until a slot frees up" do
      buffer.push(job(1), job(2))

      woke = false
      thread = Thread.new do
        buffer.wait_for_space(5)
        woke = true
      end

      sleep 0.05
      expect(woke).to eq(false)

      buffer.shift

      thread.join(1)
      expect(woke).to eq(true)
    end

    it "returns once the buffer is stopped" do
      buffer.push(job(1), job(2))

      thread = Thread.new { buffer.wait_for_space(5) }
      sleep 0.05

      buffer.stop
      expect(thread.join(1)).to_not be_nil
    end
  end

  describe "#clear" do
    it "drains and returns all buffered jobs" do
      buffer.push(job(1), job(2))
      jobs = buffer.clear

      expect(jobs.map { |j| j[:job_id] }).to contain_exactly(1, 2)
      expect(buffer.size).to eq(0)
    end
  end

  RSpec::Matchers.define :take_less_than do |seconds|
    match do |actual|
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      actual.call
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start < seconds
    end
    supports_block_expectations
  end
end
