# frozen_string_literal: true

module Kent
  class Railtie < Rails::Railtie
    config.que = Kent

    Kent.logger         = proc { Rails.logger }
    Kent.mode           = :sync if Rails.env.test?
    Kent.connection     = ::ActiveRecord if defined? ::ActiveRecord
    Kent.json_converter = :with_indifferent_access.to_proc

    rake_tasks do
      load "kent/rake_tasks.rb"
    end
  end
end
