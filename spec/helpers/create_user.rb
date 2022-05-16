# frozen_string_literal: true

class CreateUser < Kent::Job
  def run(name)
    User.create(name: name)
  end
end
