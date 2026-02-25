# frozen_string_literal: true

require "spec_helper"

RSpec.describe Que::Middleware::WorkerHealthCheck do
  subject(:health_check) { described_class.new(worker_group) }

  let(:worker_group) { instance_double(Que::WorkerGroup, workers: workers) }

  describe "#call" do
    context "when all workers are healthy" do
      let(:workers) do
        [
          instance_double(Que::Worker, healthy?: true),
          instance_double(Que::Worker, healthy?: true),
        ]
      end

      it "returns 200 with a healthy body" do
        status, _, body = health_check.call({})
        expect(status).to eq(200)
        expect(body).to eq(["healthy"])
      end
    end

    context "when one worker is in a postgres_error state" do
      let(:workers) do
        [
          instance_double(Que::Worker, healthy?: true),
          instance_double(Que::Worker, healthy?: false),
        ]
      end

      it "returns 200" do
        status, = health_check.call({})
        expect(status).to eq(200)
      end
    end

    context "when all workers are in a postgres_error state" do
      let(:workers) do
        [
          instance_double(Que::Worker, healthy?: false),
          instance_double(Que::Worker, healthy?: false),
        ]
      end

      it "returns 503 with an unhealthy body" do
        status, _, body = health_check.call({})
        expect(status).to eq(503)
        expect(body).to eq(["unhealthy"])
      end
    end

    context "when there are no workers" do
      let(:workers) { [] }

      it "returns 200" do
        status, = health_check.call({})
        expect(status).to eq(200)
      end
    end
  end
end
