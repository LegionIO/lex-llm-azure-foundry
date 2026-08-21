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

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    # Subscription dispatch invokes the runner as
    # runner_class.send(fn, **message) — the envelope arrives as kwargs.
    result = described_class.handle_fleet_request(**payload, delivery:, properties:)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: payload.merge(delivery:, properties:),
      provider_family: :azure_foundry,
      delivery: delivery,
      properties: properties
    )
  end
end
