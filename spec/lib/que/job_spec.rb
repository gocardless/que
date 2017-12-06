# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Job do
  describe ".enqueue" do
    let(:run_at) { postgres_now }

    it "adds job to que_jobs table" do
      expect { Que::Job.enqueue(:hello, run_at: run_at) }.
        to change { QueJob.count }.
        from(0).to(1)

      job = QueJob.last

      expect(job.id).not_to be_nil
      expect(job.run_at).to eql(run_at)
      expect(job.args).to eql(["hello"])
    end

    context "with no args" do
      it "adds job to que_jobs table, setting a run_at of the current time" do
        expect { Que::Job.enqueue }.
          to change { QueJob.count }.
          from(0).to(1)

        job = QueJob.last

        expect(job.id).not_to be_nil
        expect(job.run_at).to be < postgres_now
        expect(job.args).to eql([])
      end
    end

    fake_args = {
      job_class: "A::Job",
      queue: "a_queue",
      priority: 10,
      run_at: postgres_now,
      retryable: true
    }

    (1..fake_args.keys.count).
      map { |n| fake_args.keys.combination(n).to_a }.flatten(1).each do |arg_keys|
      context "with #{arg_keys.inspect}" do
        let(:args) { Hash[arg_keys.zip(fake_args.values_at(*arg_keys))] }

        it "handles them properly" do
          described_class.enqueue(1, true, "foo", { a_real_arg: true }.merge(args))
          job = QueJob.last

          arg_keys.each do |key|
            expect(job.send(key)).to eq(fake_args[key])
          end

          expect(job.args).to eq([1, true, "foo", { "a_real_arg" => true }])
        end
      end
    end

    context "when in sync mode" do
      around do |example|
        Que.mode.tap do |old_mode|
          Que.mode = :sync
          example.run
          Que.mode = old_mode
        end
      end

      it "runs the job synchronously" do
        FakeJob.enqueue(1)

        expect(FakeJob.log).to eq([1])
      end
    end
  end

  describe ".run" do
    it "news up a job and runs it" do
      FakeJob.run(1)

      expect(FakeJob.log).to eq([1])
    end
  end

  describe ".default_attrs" do
    it "returns default attributes if none are set" do
      expect(described_class.default_attrs).
        to eq(
          job_class: "Que::Job",
          queue: nil,
          priority: nil,
          run_at: nil,
          retryable: true,
      )
    end

    it "permits setting queue at a class level" do
      job_class = Class.new(described_class) { @queue = "foo" }

      expect(job_class.default_attrs[:queue]).to eq("foo")
    end

    it "permits setting priority at a class level" do
      job_class = Class.new(described_class) { @priority = 99 }

      expect(job_class.default_attrs[:priority]).to eq(99)
    end

    it "permits setting run_at at a class level" do
      run_at = postgres_now
      job_class = Class.new(described_class) { @run_at = -> { run_at } }

      expect(job_class.default_attrs[:run_at]).to eq(run_at)
    end
  end
end
