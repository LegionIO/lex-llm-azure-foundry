# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/azure_foundry/runners/fleet_worker'

FleetWorkerSpecDelivery = Class.new unless defined?(FleetWorkerSpecDelivery)
FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Runners::FleetWorker do
  let(:payload) { { request_id: 'req-1', provider: 'azure_foundry', provider_instance: 'local' } }
  let(:delivery) { instance_double(FleetWorkerSpecDelivery) }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }
  let(:instances) { { local: { fleet: { respond_to_requests: true } } } }

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances).and_return(instances)
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    # Subscription dispatch invokes the runner as
    # runner_class.send(fn, **message) — the envelope arrives as kwargs.
    result = described_class.handle_fleet_request(**payload, delivery:, properties:)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call) do |args|
      expect(args[:provider_family]).to eq(:azure_foundry)
      expect(args[:provider_class]).to eq(Legion::Extensions::Llm::AzureFoundry::Provider)
      expect(args[:registry]).to eq(Legion::Extensions::Llm::Inventory::Registry)
      expect(args[:delivery]).to be(delivery)
      expect(args[:properties]).to be(properties)
      expect(args[:payload]).to include(payload.merge(delivery:, properties:))
      expect(args[:provider_instances].call).to eq(instances)
    end
  end
end
