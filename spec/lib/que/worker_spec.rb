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

      it "logs the work without custom log context" do
        expect(Que.logger).to receive(:info).
          with(hash_including(
                 event: "que_job.job_begin",
                 handler: "FakeJob",
                 job_class: "FakeJob",
                 job_error_count: 0,
                 msg: "Job acquired, beginning work",
                 priority: 100,
                 queue: "default",
                 que_job_id: job.attrs["job_id"],
                 latency: an_instance_of(Float),
               ))

        expect(Que.logger).to receive(:info).
          with(hash_including(
                 duration: kind_of(Float),
                 event: "que_job.job_worked",
                 handler: "FakeJob",
                 job_class: "FakeJob",
                 job_error_count: 0,
                 msg: "Successfully worked job",
                 priority: 100,
                 queue: "default",
                 que_job_id: job.attrs["job_id"],
               ))
        subject
      end

      context "with custom log context" do
        let!(:job) do
          class FakeJobWithCustomLogs < FakeJob
            custom_log_context ->(attrs) {
              {
                custom_log_1: attrs[:args][0],
                custom_log_2: "test-log",
              }
            }

            @log = []
          end
          FakeJobWithCustomLogs.enqueue(1)
        end

        it "logs the work with custom log context" do
          expect(Que.logger).to receive(:info).
            with(hash_including(
                   event: "que_job.job_begin",
                   handler: "FakeJobWithCustomLogs",
                   job_class: "FakeJobWithCustomLogs",
                   job_error_count: 0,
                   msg: "Job acquired, beginning work",
                   priority: 100,
                   queue: "default",
                   que_job_id: job.attrs["job_id"],
                   latency: an_instance_of(Float),
                   custom_log_1: 1,
                   custom_log_2: "test-log",
                 ))

          expect(Que.logger).to receive(:info).
            with(hash_including(
                   duration: kind_of(Float),
                   event: "que_job.job_worked",
                   handler: "FakeJobWithCustomLogs",
                   job_class: "FakeJobWithCustomLogs",
                   job_error_count: 0,
                   msg: "Successfully worked job",
                   priority: 100,
                   queue: "default",
                   que_job_id: job.attrs["job_id"],
                   custom_log_1: 1,
                   custom_log_2: "test-log",
                 ))
          subject
        end
      end
    end

    context "when a job raises an exception" do
      it "rescues it" do
        ExceptionalJob.enqueue(1)

        expect(subject).to eq(:job_worked)
      end

      it "logs the work" do
        class ExceptionalJobWithCustomLogging < ExceptionalJob
          custom_log_context -> (attrs) {
            {
              first_arg: attrs[:args][0],
            }
          }

          @log = []
        end

        ExceptionalJobWithCustomLogging.enqueue(1)

        expect(Que.logger).to receive(:info).
          with(hash_including(
                 event: "que_job.job_begin",
                 handler: "ExceptionalJobWithCustomLogging",
                 job_class: "ExceptionalJobWithCustomLogging",
                 msg: "Job acquired, beginning work",
                 first_arg: 1
               ))

        expect(Que.logger).to receive(:error).
          with(hash_including(
                 event: "que_job.job_error",
                 handler: "ExceptionalJobWithCustomLogging",
                 job_class: "ExceptionalJobWithCustomLogging",
                 msg: "Job failed with error",
                 error: "#<ExceptionalJob::Error: bad argument 1>",
                 first_arg: 1
               ))

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

      context "when the job is no longer defined" do
        it "marks it as failed" do
          job_options = {
            queue: "default",
            priority: 1,
            run_at: nil,
            job_class: "JobNotFound",
            retryable: true,
          }

          Que.adapter.execute(:insert_job, [*job_options.values_at(*Que::Job::JOB_OPTIONS), []])

          expect(subject).to eq(:job_worked)

          job = QueJob.first

          expect(job.error_count).to eq(1)
          expect(job.run_at).to be > postgres_now
          expect(job.last_error).to match("uninitialized constant JobNotFound")
        end
      end

      context "when postgres raises an exception while processing a job" do
        it "rescues it and returns an error" do
          FakeJob.enqueue(1)

          expect(Que).
            to receive(:execute).with(:lock_job, ["default", 0]).and_raise(PG::Error)
          expect(subject).to eq(:postgres_error)
        end
      end

      context "when we time out checking out a new connection" do
        it "rescues it and returns an error" do
          FakeJob.enqueue(1)

          expect(Que).
            to receive(:execute).with(:lock_job, ["default", 0]).
            and_raise(ActiveRecord::ConnectionTimeoutError)
          expect(subject).to eq(:postgres_error)
        end
      end

      context "when we can't connect to postgres" do
        it "rescues it and returns an error" do
          FakeJob.enqueue(1)

          expect(Que).
            to receive(:execute).with(:lock_job, ["default", 0]).
            and_raise(ActiveRecord::ConnectionNotEstablished)
          expect(subject).to eq(:postgres_error)
        end
      end
    end
  end
end
