# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Worker do
  describe ".work" do
    subject { described_class.new.work }

    it "works a job if there's one to work" do
      FakeJob.enqueue(1)

      expect(subject).to eq(:job_worked)
      expect(FakeJob.log).to eq([1])
      expect(QueJob.count).to eq(0)
    end

    it "returns job_not_found if there's no job to work" do
      expect(subject).to eq(:job_not_found)
    end

    context "if the job raises an exception" do
      it "rescues it" do
        ExceptionalJob.enqueue(1)

        expect(subject).to eq(:job_worked)
      end

      context "if the job has a failure handler" do
        let(:job_class) { ExceptionalJob::WithFailureHandler }

        it "calls it" do
          job_class.enqueue(1)

          expect(subject).to eq(:job_worked)

          expect(job_class.log.count).to eq(2)
          expect(job_class.log.first).to eq([:run, 1])

          method, error, job = job_class.log.second

          expect(method).to eq(:handle_job_failure)
          expect(error.class).to eq(ExceptionalJob::Error)
          expect(job).to be_a(Hash)
        end
      end

      context "if the job doesn't have a failure handler" do
        let(:job_class) { ExceptionalJob }

        it "calls the default one" do
          job_class.enqueue("foo")

          expect(subject).to eq(:job_worked)

          job = QueJob.first

          expect(job.error_count).to eq(1)
          expect(job.run_at).to be > postgres_now
          expect(job.last_error).to match("bad argument foo")
        end
      end

      context "if postgres raises an exception while processing a job" do
        it "rescues it and returns error" do
          FakeJob.enqueue(1)

          expect(Que).to receive(:execute).with(:lock_job, [""]).and_raise(PG::Error)

          expect(subject).to eq(:error)
        end
      end
    end
  end
end
