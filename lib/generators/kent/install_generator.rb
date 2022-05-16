# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "active_record"

module Kent
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    namespace "kent:install"
    source_paths << File.join(File.dirname(__FILE__), "templates")
    desc "Generates a migration to add Kent's job table."

    def self.next_migration_number(dirname)
      next_migration_number = current_migration_number(dirname) + 1
      ActiveRecord::Migration.next_migration_number(next_migration_number)
    end

    def create_migration_file
      migration_template "add_kent.rb", "db/migrate/add_kent.rb"
    end
  end
end
