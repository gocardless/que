# frozen_string_literal: true

namespace :que do
  desc "Migrate Kent's job table to the most recent version (creating it if necessary)"
  task migrate: :environment do
    Kent.migrate!
  end

  desc "Drop Kent's job table"
  task drop: :environment do
    Kent.drop!
  end

  desc "Clear Kent's job table"
  task clear: :environment do
    Kent.clear!
  end
end
