# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/azure_foundry/runners/discovery'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Runners::Discovery do
  let(:runner) { described_class }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:project_url) { 'https://project.example/api/projects/primary' }
  let(:resource_url) { 'https://resource.example/openai/v1/models' }
  let(:deployment_url) { "#{project_url}/deployments?api-version=v1" }
  let(:instance) do
    {
      endpoint: 'https://resource.example', tier: :cloud,
      credentials: { api_key: 'data-plane-key', bearer_token: 'data-plane-token',
                     project_bearer_token: 'project-token' },
      provider: { surface: :openai_v1, project_endpoint: project_url }
    }
  end
  let(:deployment) do
    {
      name: 'production-chat', type: 'ModelDeployment', modelName: 'base-model', modelVersion: '2026-01',
      capabilities: { chat_completion: true, embeddings: false, function_calling: true, streaming: true }
    }
  end

  def tree = Legion::Settings[:extensions][:llm][:azure_foundry]
  def config = Legion::Extensions::Llm::AzureFoundry.discover_instances.fetch(:primary)
  def response(status: 200, **body) = [status, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]

  before do
    registry.reset!
    runner.reset_state!
    defaults = Legion::Extensions::Llm::AzureFoundry.default_settings
    Legion::Settings[:extensions][:llm] = { azure_foundry: defaults.merge(instances: { primary: instance }) }
    allow(runner).to receive(:build_connection).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap { |connection| connection.adapter(:test, stubs) }
    end
  end

  after do
    runner.remove_all_instances
    registry.reset!
    runner.reset_state!
  end

  it 'publishes paginated deployments through the shared lifecycle and reads the same registry' do
    stubs.get(deployment_url) do |env|
      expect(env.request_headers['Authorization']).to eq('Bearer project-token')
      expect(env.request_headers).not_to have_key('api-key')
      response(value: [deployment], nextLink: "#{deployment_url}&skip=1")
    end
    stubs.get("#{deployment_url}&skip=1") do
      response(value: [deployment.merge(name: 'secondary-chat')])
    end
    stubs.get(resource_url) do |env|
      expect(env.request_headers['api-key']).to eq('data-plane-key')
      expect(env.request_headers['Authorization']).to eq('Bearer data-plane-token')
      response(data: [])
    end

    runner.refresh

    expect(runner.method(:refresh).owner).to eq(Legion::Extensions::Llm::Discovery::Pipeline)
    lanes = registry.snapshot.each_lane.to_a
    expect(lanes.map(&:model)).to contain_exactly('production-chat', 'secondary-chat')
    expect(runner.states.fetch('primary')[:offerings].map(&:provider_native_key))
      .to contain_exactly('production-chat', 'secondary-chat')
    expect(lanes.map { |lane| lane.metadata[:canonical_model_alias] }).to all(eq('base-model'))
    expect(lanes.map { |lane| lane.model_revision_evidence.value }).to all(eq('2026-01'))
    provider = Legion::Extensions::Llm::AzureFoundry::Provider.new(config.merge(instance_id: 'primary'))
    expect(provider.discover_offerings.map(&:lane_id)).to match_array(lanes.map(&:lane_id))
    stubs.verify_stubbed_calls
  end

  it 'keeps the last good snapshot when a later page fails instead of publishing a partial catalog' do
    broken = false
    stubs.get(deployment_url) do
      response(value: [deployment], nextLink: broken ? "#{deployment_url}&skip=1" : nil)
    end
    stubs.get("#{deployment_url}&skip=1") { response(error: { code: 'ServiceUnavailable' }, status: 503) }
    stubs.get(resource_url) { response(data: []) }
    runner.refresh
    previous = registry.snapshot.each_lane.map(&:lane_id)
    expect(previous).not_to be_empty

    broken = true
    runner.refresh

    expect(registry.snapshot.each_lane.map(&:lane_id)).to eq(previous)
    expect(runner.states.fetch('primary')[:sequence]).to eq(0)
  end

  it 'does not send a project bearer token to an off-origin nextLink' do
    stubs.get(deployment_url) do
      response(value: [deployment], nextLink: 'https://other.example/deployments')
    end

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /same project/)
    stubs.verify_stubbed_calls
  end

  it 'rejects repeated pagination links before requesting them again' do
    stubs.get(deployment_url) { response(value: [deployment], nextLink: deployment_url) }

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /cycle/)
  end

  it 'honors the configured pagination bound' do
    tree[:discovery][:max_pages] = 1
    stubs.get(deployment_url) { response(value: [deployment], nextLink: "#{deployment_url}&skip=1") }

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /max_pages/)
  end

  it 'requires an independently configured project credential instead of reusing a resource credential' do
    tree[:instances][:primary][:credentials].delete(:project_bearer_token)

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /project_bearer_token/)
  end

  it 'rejects a malformed nextLink without publishing the first page' do
    stubs.get(deployment_url) { response(value: [deployment], nextLink: 42) }

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /nextLink must be a string/)
  end

  it 'publishes a complete empty snapshot when the deployment list is genuinely empty' do
    stubs.get(deployment_url) { response(value: []) }
    stubs.get(resource_url) { response(data: []) }

    runner.refresh

    key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: :azure_foundry,
                                                                        instance_id: 'primary')
    expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    expect(registry.snapshot.each_lane.to_a).to be_empty
  end

  it 'rejects conflicting capabilities for the same deployment across pages' do
    stubs.get(deployment_url) { response(value: [deployment], nextLink: "#{deployment_url}&skip=1") }
    stubs.get("#{deployment_url}&skip=1") do
      response(value: [deployment.merge(capabilities: { chat_completion: false })])
    end

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /conflicting/)
  end

  it 'publishes only project-native deployments from a mixed project catalog' do
    connected = deployment.merge(name: 'connected-chat', connectionName: 'connected-resource')
    stubs.get(deployment_url) { response(value: [connected, deployment.merge(connectionName: nil)]) }
    stubs.get(resource_url) { response(data: []) }

    runner.refresh

    expect(registry.snapshot.each_lane.map(&:model)).to eq(['production-chat'])
    stubs.verify_stubbed_calls
  end

  it 'replaces the native snapshot with an empty one when only connected-resource deployments remain' do
    entries = [deployment]
    stubs.get(deployment_url) { response(value: entries) }
    stubs.get(resource_url) { response(data: []) }
    runner.refresh
    expect(registry.snapshot.each_lane.map(&:model)).to eq(['production-chat'])

    entries = [deployment.merge(connectionName: 'connected-resource')]
    runner.refresh

    key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: :azure_foundry,
                                                                        instance_id: 'primary')
    expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    expect(registry.snapshot.each_lane.to_a).to be_empty
    stubs.verify_stubbed_calls
  end

  it 'does not let a connected deployment conflict with a native deployment of the same name' do
    connected = deployment.merge(connectionName: 'connected-resource',
                                 capabilities: { chat_completion: false, embeddings: true })
    stubs.get(deployment_url) { response(value: [connected, deployment]) }
    stubs.get(resource_url) { response(data: []) }

    runner.refresh

    offering = runner.states.fetch('primary')[:offerings].first
    expect(registry.snapshot.each_lane.map(&:model)).to eq(['production-chat'])
    expect(offering.operation_evidence[:chat].status).to eq(:supported)
    expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    stubs.verify_stubbed_calls
  end

  it 'rejects an invalid connection identity rather than treating it as project-native' do
    stubs.get(deployment_url) { response(value: [deployment.merge(connectionName: false)]) }

    expect { runner.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /connectionName/)
  end
end
