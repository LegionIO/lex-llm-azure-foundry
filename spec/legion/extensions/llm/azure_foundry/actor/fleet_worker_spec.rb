# frozen_string_literal: true

require 'spec_helper'

require 'legion/extensions/llm/azure_foundry/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Actor::FleetWorker do
  # These routing methods need no AMQP consumer initialization.
  subject(:actor) { described_class.allocate }

  it 'inherits the actual host subscription lifecycle' do
    expect(described_class.superclass).to eq(Legion::Extensions::Actors::Subscription)
    expect(actor.method(:initialize).owner).to eq(Legion::Extensions::Actors::Subscription)
    expect(actor.method(:prepare).owner).to eq(Legion::Extensions::Actors::Subscription)
  end

  # D13: the Subscription dispatch path (use_runner? == false) calls
  # runner_class.send(runner_function, **message) — runner_class must be the
  # runner constant (a String cannot be send-ed) and the runner entry point
  # must accept the decoded message as keyword arguments.
  it 'uses the provider-owned fleet runner constant with a kwargs entry point' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::AzureFoundry::Runners::FleetWorker)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end
end
