RSpec.describe Que::Job do
  describe ".enqueue" do
    let(:run_at) { Time.now }

    def postgres_now
      now = ActiveRecord::Base.connection.execute("SELECT NOW();")[0]["now"]
      Time.parse(now)
    end

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
      it "adds job to que_jobs table" do
        expect { Que::Job.enqueue }.
          to change { QueJob.count }.
          from(0).to(1)

        job = QueJob.last

        expect(job.id).not_to be_nil
        expect(job.run_at).to be < postgres_now
        expect(job.args).to eql([])
      end
    end
  end
end
