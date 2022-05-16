# frozen_string_literal: true

shared_examples "a Kent adapter" do
  it "should be able to execute arbitrary SQL and return indifferent hashes" do
    result = Kent.execute("SELECT 1 AS one")
    result.should == [{'one'=>1}]
    result.first[:one].should == 1
  end

  it "should be able to execute multiple SQL statements in one string" do
    Kent.execute("SELECT 1 AS one; SELECT 1 AS one")
  end

  it "should be able to queue and work a job" do
    Kent::Job.enqueue
    result = Kent::Job.work
    result[:event].should == :job_worked
    result[:job][:job_class].should == 'Kent::Job'
  end

  it "should yield the same Postgres connection for the duration of the block" do
    Kent.adapter.checkout do |conn|
      conn.should be_a PG::Connection
      pid1 = Kent.execute "SELECT pg_backend_pid()"
      pid2 = Kent.execute "SELECT pg_backend_pid()"
      pid1.should == pid2
    end
  end

  it "should allow nested checkouts" do
    Kent.adapter.checkout do |a|
      Kent.adapter.checkout do |b|
        a.object_id.should == b.object_id
      end
    end
  end
end
