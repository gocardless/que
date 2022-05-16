# frozen_string_literal: true

require 'spec_helper'

describe Kent::Migrations do
  it "should be able to perform migrations up and down" do
    # Migration #1 creates the table with a priority default of 1, migration
    # #2 ups that to 100.

    default = proc do
      result = Kent.execute <<-SQL
        select adsrc::integer
        from pg_attribute a
        join pg_class c on c.oid = a.attrelid
        join pg_attrdef on adrelid = attrelid AND adnum = attnum
        where relname ='kent_jobs'
        and attname = 'priority'
      SQL

      result.first[:adsrc]
    end

    default.call.should == 100
    Kent::Migrations.migrate! :version => 1
    default.call.should == 1
    Kent::Migrations.migrate! :version => 2
    default.call.should == 100

    # Clean up.
    Kent.migrate!
  end

  it "should be able to get and set the current schema version" do
    Kent::Migrations.db_version.should == Kent::Migrations::CURRENT_VERSION
    described_class.db_version = 59328
    described_class.db_version.should == 59328
    described_class.db_version = Kent::Migrations::CURRENT_VERSION
    Kent::Migrations.db_version.should == Kent::Migrations::CURRENT_VERSION
  end

  it "should be able to cycle the jobs table all the way between nonexistent and current without error" do
    Kent::Migrations.db_version.should == Kent::Migrations::CURRENT_VERSION
    Kent::Migrations.migrate! :version => 0
    Kent::Migrations.db_version.should == 0
    Kent.db_version.should == 0
    Kent::Migrations.migrate!
    Kent::Migrations.db_version.should == Kent::Migrations::CURRENT_VERSION

    # The helper on the Kent module does the same thing.
    Kent.migrate! :version => 0
    Kent::Migrations.db_version.should == 0
    Kent.migrate!
    Kent::Migrations.db_version.should == Kent::Migrations::CURRENT_VERSION
  end

  it "should be able to honor the initial behavior of Kent.drop!" do
    DB.table_exists?(:kent_jobs).should be true
    Kent.drop!
    DB.table_exists?(:kent_jobs).should be false

    # Clean up.
    Kent::Migrations.migrate!
    DB.table_exists?(:kent_jobs).should be true
  end

  it "should be able to recognize a que_jobs table created before the versioning system" do
    DB.drop_table :kent_jobs
    DB.create_table(:kent_jobs){serial :id} # Dummy Table.
    Kent::Migrations.db_version.should == 1
    DB.drop_table(:kent_jobs)
    Kent::Migrations.migrate!
  end

  it "should be able to honor the initial behavior of Kent.create!" do
    DB.drop_table :kent_jobs
    Kent.create!
    DB.table_exists?(:kent_jobs).should be true
    Kent::Migrations.db_version.should == 1

    # Clean up.
    Kent::Migrations.migrate!
    DB.table_exists?(:kent_jobs).should be true
  end
end
