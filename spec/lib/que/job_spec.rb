# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Job do
  describe ".enqueue" do
    let(:run_at) { postgres_now }

    it "adds job to que_jobs table" do
      expect { described_class.enqueue(:hello, run_at: run_at) }.
        to change(QueJob, :count).
        from(0).to(1)

      job = QueJob.last

      expect(job.id).to_not be_nil
      expect(job.run_at).to eql(run_at)
      expect(job.args).to eql(["hello"])
    end

    context "logs" do
      it "logs to que logger" do
        expect(Que.logger).to receive(:info).with(
          event: "que_job.job_enqueued",
          msg: "Job enqueued",
          que_job_id: an_instance_of(Integer),
          queue: "default",
          priority: 100,
          job_class: "Que::Job",
          retryable: true,
          run_at: run_at,
          args: ["hello"],
        )

        described_class.enqueue(:hello, run_at: run_at)
      end

      it "logs custom context to que logger" do
        expect(Que.logger).to receive(:info).with(
          event: "que_job.job_enqueued",
          msg: "Job enqueued",
          que_job_id: an_instance_of(Integer),
          queue: "default",
          priority: 100,
          job_class: a_string_including("Class"),
          retryable: true,
          run_at: run_at,
          args: [500, "gbp", "testing"],
          custom_log_1: 500,
          custom_log_2: "test-log",
        )

        job_class = Class.new(described_class)
        job_class.custom_log_context ->(job) {
          {
            custom_log_1: job.attrs[:args][0],
            custom_log_2: "test-log",
          }
        }
        job_class.enqueue(500, :gbp, :testing,  run_at: run_at)
      end
    end

    context "with a custom adapter specified" do
      let(:custom_adapter) { Que.adapter.dup }
      let(:job_with_adapter) { Class.new(described_class) }

      before { job_with_adapter.use_adapter(custom_adapter) }

      it "uses the custom adapter" do
        expect(custom_adapter).to receive(:execute).and_call_original

        job_with_adapter.enqueue(:hello, run_at: run_at)
      end
    end

    context "with no args" do
      it "adds job to que_jobs table, setting a run_at of the current time" do
        expect { described_class.enqueue }.
          to change(QueJob, :count).
          from(0).to(1)

        job = QueJob.last

        expect(job.id).to_not be_nil
        expect(job.run_at).to be < postgres_now
        expect(job.args).to eql([])
      end
    end

    fake_args = {
      job_class: "A::Job",
      queue: "a_queue",
      priority: 10,
      run_at: postgres_now,
      retryable: true,
    }

    (1..fake_args.keys.count).
      flat_map { |n| fake_args.keys.combination(n).to_a }.each do |arg_keys|
      context "with #{arg_keys.inspect}" do
        let(:args) { Hash[arg_keys.zip(fake_args.values_at(*arg_keys))] }

        it "handles them properly" do
          described_class.enqueue(1, true, "foo", **{ a_real_arg: true }.merge(args))
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

  describe ".adapter" do
    context "with an adapter specified" do
      let(:custom_adapter) { double(Que::Adapters::Base) }
      let(:job_with_adapter) { Class.new(described_class) }

      it "uses the correct adapter" do
        expect(described_class.adapter).to eq(Que.adapter)

        job_with_adapter.use_adapter(custom_adapter)

        expect(job_with_adapter.adapter).to eq(custom_adapter)
      end
    end
  end

  describe ".run" do
    it "news up a job and runs it" do
      FakeJob.run(1)

      expect(FakeJob.log).to eq([1])
    end
  end

  describe ".destroy" do
    context "with a custom adapter specified" do
      let(:run_at) { postgres_now }
      let(:custom_adapter) { Que.adapter.dup }
      let(:job_with_adapter) { Class.new(described_class) }

      before { job_with_adapter.use_adapter(custom_adapter) }

      it "uses the custom adapter" do
        job = job_with_adapter.enqueue(:hello, run_at: run_at)

        expect(custom_adapter).to receive(:execute).and_call_original

        job.destroy
      end
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

  describe ".custom_log_context" do
    let!(:job_class) { Class.new(described_class) }

    it "adds static tags" do
      job_class.custom_log_context -> (_) {
        {
          test_key_1: "One",
          test_key_2: "Two",
        }
      }

      test_instance = job_class.enqueue("irrelevant-arg")

      expect(test_instance.get_custom_log_context).to eq({
        test_key_1: "One",
        test_key_2: "Two",
      })
    end

    it "adds dynamic tags" do
      job_class.custom_log_context -> (job) {
        {
          first_argument: job.attrs[:args][0],
          second_argument: job.attrs[:args][1],
          third_argument: job.attrs[:args][2],
          adapter: job.class.adapter.class.to_s,
        }
      }

      test_instance = job_class.enqueue("a", 2, false)

      expect(test_instance.get_custom_log_context).to eq({
        first_argument: "a",
        second_argument: 2,
        third_argument: false,
        adapter: "Que::Adapters::ActiveRecord",
      })
    end

    it "raises an ArgumentError unless given a proc" do
      msg = "Custom log context must be a Proc which receives the job as an argument and returns a hash"

      expect { job_class.custom_log_context 100 }.
        to raise_error(ArgumentError, msg)

      test_instance = job_class.enqueue("irrelevant-arg")

      expect(test_instance.get_custom_log_context).to eq({})
    end
  end
end
