# frozen_string_literal: true

class AddQue < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def self.up
    # The current version as of this migration's creation.
    Que.migrate!
  end

  def self.down
    # Completely removes Que's job queue.
    Que.migrate! version: 0
  end
end
