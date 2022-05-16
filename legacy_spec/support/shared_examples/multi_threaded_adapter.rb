# frozen_string_literal: true

shared_examples "a multi-threaded Kent adapter" do
  it_behaves_like "a Kent adapter"

  it "should allow multiple threads to check out their own connections" do
    one = nil
    two = nil

    q1, q2 = Queue.new, Queue.new

    thread = Thread.new do
      Kent.adapter.checkout do |conn|
        q1.push nil
        q2.pop
        one = conn.object_id
      end
    end

    Kent.adapter.checkout do |conn|
      q1.pop
      q2.push nil
      two = conn.object_id
    end

    thread.join
    one.should_not == two
  end

  it "should allow multiple workers to complete jobs simultaneously" do
    BlockJob.enqueue
    worker_1 = Kent::Worker.new
    $q1.pop

    Kent::Job.enqueue
    DB[:kent_jobs].count.should be 2

    worker_2 = Kent::Worker.new
    sleep_until { worker_2.sleeping? }
    DB[:kent_jobs].count.should be 1

    $q2.push nil
    sleep_until { worker_1.sleeping? }
    DB[:kent_jobs].count.should be 0
  end
end
