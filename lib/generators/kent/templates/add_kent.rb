# frozen_string_literal: true

class AddKent < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def self.up
    # The current version as of this migration's creation.
    Kent.migrate!
  end

  def self.down
    # Completely removes Kent's job queue.
    Kent.migrate! version: 0
  end
end
