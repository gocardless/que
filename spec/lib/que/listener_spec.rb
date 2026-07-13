# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Listener do
  subject(:listener) { described_class.new(queues: queues, wakeup: wakeup) }

  let(:wakeup) { { mutex: Mutex.new, condvar: ConditionVariable.new } }
  let(:queues) { ["default"] }

  after { listener.stop }

  # Blocks in a separate thread on the wakeup condvar, and returns whether it was woken
  # (true) or timed out (false). Only safe to call once the listener has had a chance to
  # issue its LISTEN statement(s).
  def wait_for_wakeup(timeout: 5)
    woken = nil
    waiter = Thread.new do
      wakeup.fetch(:mutex).synchronize do
        woken = wakeup.fetch(:condvar).wait(wakeup.fetch(:mutex), timeout)
      end
    end

    # Give the waiter thread a moment to actually be blocked in condvar.wait before we
    # trigger a notification - otherwise we might notify before anyone is listening.
    sleep 0.1

    yield

    waiter.join(timeout)
    !woken.nil?
  end

  it "wakes up when a notification arrives on a listened queue" do
    listener.start
    sleep 0.2 # give the listener time to issue LISTEN

    woken = wait_for_wakeup do
      Que.execute("SELECT pg_notify('que_job_available_default', '{}')")
    end

    expect(woken).to eq(true)
  end

  it "does not wake up for a queue it isn't listening to" do
    listener.start
    sleep 0.2

    woken = wait_for_wakeup(timeout: 0.5) do
      Que.execute("SELECT pg_notify('que_job_available_other', '{}')")
    end

    expect(woken).to eq(false)
  end

  it "wakes up when a real job is enqueued on a listened queue" do
    listener.start
    sleep 0.2

    woken = wait_for_wakeup do
      FakeJob.enqueue(1)
    end

    expect(woken).to eq(true)
  end

  it "stops cleanly" do
    listener.start
    sleep 0.2

    expect { listener.stop }.to_not raise_error
  end
end
