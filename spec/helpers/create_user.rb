# frozen_string_literal: true

class CreateUser < Que::Job
  def run(name)
    User.create(name: name)
  end
end
