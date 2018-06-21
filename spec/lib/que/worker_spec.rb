# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Worker do
  describe ".work" do
    subject { described_class.new.work }

    it "returns job_not_found if there's no job to work" do
      expect(subject).to eq(:job_not_found)
    end

    context "when there's a job to work" do
      let!(:job) { FakeJob.enqueue(1) }

      it "works the job" do
        expect(subject).to eq(:job_worked)
        expect(FakeJob.log).to eq([1])
        expect(QueJob.count).to eq(0)
      end

      it "logs the work" do
        expect(Que.logger).to receive(:info).
          with(hash_including({
            event: "que_job.job_begin",
            handler: "FakeJob",
            job_class: "FakeJob",
            job_error_count: 0,
            msg: "Job acquired, beginning work",
            priority: 100,
            queue: "",
            que_job_id: job.attrs["job_id"],
          }))

        expect(Que.logger).to receive(:info).
          with(hash_including({
            duration: kind_of(Float),
            event: "que_job.job_worked",
            handler: "FakeJob",
            job_class: "FakeJob",
            job_error_count: 0,
            msg: "Successfully worked job",
            priority: 100,
            queue: "",
            que_job_id: job.attrs["job_id"],
          }))

        subject
      end
    end

    context "when a job raises an exception" do
      it "rescues it" do
        ExceptionalJob.enqueue(1)

        expect(subject).to eq(:job_worked)
      end

      it "logs the work" do
        ExceptionalJob.enqueue(1)

        expect(Que.logger).to receive(:info).
          with(hash_including({
            event: "que_job.job_begin",
            handler: "ExceptionalJob",
            job_class: "ExceptionalJob",
            msg: "Job acquired, beginning work",
          }))

        expect(Que.logger).to receive(:error).
          with(hash_including({
            event: "que_job.job_error",
            handler: "ExceptionalJob",
            job_class: "ExceptionalJob",
            msg: "Job failed with error",
          }))

        subject
      end

      context "and the job has a failure handler" do
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

      context "when the job doesn't have a failure handler" do
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

      context "when postgres raises an exception while processing a job" do
        it "rescues it and returns an error" do
          FakeJob.enqueue(1)

          expect(Que).to receive(:execute).with(:lock_job, ["", 0, 0]).and_raise(PG::Error)
          expect(subject).to eq(:postgres_error)
        end
      end
    end
  end
end
