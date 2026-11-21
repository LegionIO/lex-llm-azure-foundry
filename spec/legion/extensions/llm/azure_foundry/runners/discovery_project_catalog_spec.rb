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
      credentials: { api_key: 'data-plane-key', project_bearer_token: 'project-token' },
      provider: { surface: :openai_v1, discovery_source: :project, project_endpoint: project_url }
    }
  end
  let(:deployment) do
    {
      name: 'production-chat', type: 'ModelDeployment', modelName: 'base-model', modelVersion: '2026-01',
      modelPublisher: 'Example', sku: { name: 'GlobalStandard', capacity: 1, family: '', size: '', tier: 'Standard' },
      capabilities: { chat_completion: 'true', embeddings: 'false', function_calling: 'true', streaming: 'true',
                      maxContextToken: '128000', maxOutputToken: '16384' }
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

  it 'uses the shared lifecycle for every state transition and inventory operation' do
    %i[refresh reconcile_instances update_instance claim_and_activate_instance perform_readiness
       replace_if_changed remove_instance_state publisher states state_mutex].each do |operation|
      expect(runner.method(operation).owner).to eq(Legion::Extensions::Llm::Discovery::Pipeline)
    end
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
      expect(env.request_headers).not_to have_key('Authorization')
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
    expect(lanes.map { |lane| lane.model_revision_evidence.source }).to all(eq(:provider_catalog))
    expect(lanes.map { |lane| lane.context_evidence.value }).to all(eq(128_000))
    expect(lanes.map { |lane| lane.max_output_evidence.value }).to all(eq(16_384))
    expect(lanes.map { |lane| lane.context_evidence.source }).to all(eq(:provider_catalog))
    expect(lanes.map { |lane| lane.metadata.key?(:declared) }).to all(be(false))
    provider = runner.states.fetch('primary')[:callable]
    expect(provider).to be_an_instance_of(Legion::Extensions::Llm::AzureFoundry::Provider)
    expect(provider.provider_instance_id).to eq(:primary)
    expect(provider.discover_offerings.map(&:lane_id)).to match_array(lanes.map(&:lane_id))
    stubs.verify_stubbed_calls
  end

  context 'with observed model version and SKU metadata' do
    let(:deployment) do
      {
        name: 'observed-chat', type: 'ModelDeployment', modelName: 'gpt-4.1', modelVersion: '2025-04-14',
        modelPublisher: 'OpenAI', sku: { name: 'GlobalStandard', capacity: 1, family: '', size: '', tier: 'Standard' },
        capabilities: { chat_completion: 'true', function_calling: 'false', streaming: 'false' }
      }
    end

    before do
      stubs.get(deployment_url) { response(value: [deployment]) }
      stubs.get(resource_url) { response(data: []) }
    end

    it 'uses the shared vendor metadata owner with an observed tuple and preserves observation provenance' do
      runner.refresh

      draft = runner.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.to_h).to include(status: :known, value: 1_047_576, source: :model_metadata)
      expect(draft.max_output_evidence.to_h).to include(status: :known, value: 32_768, source: :model_metadata)
      expect(draft.model_revision_evidence.to_h).to include(value: '2025-04-14', source: :provider_catalog)
      expect(draft.capability_evidence[:vision].to_h).to include(status: :supported, source: :model_metadata)
      expect(draft.capability_evidence[:thinking].to_h).to include(status: :unsupported, source: :model_metadata)
      expect(draft.capability_evidence[:tools].to_h).to include(status: :unsupported, source: :provider_catalog)
      expect(draft.operation_evidence[:stream_chat].to_h).to include(status: :unsupported, source: :provider_catalog)
      expect(draft.publication_source).to eq(:provider_catalog)
      expect(draft.metadata).not_to have_key(:declared_model_version)
      expect(draft.metadata).not_to have_key(:declared)
    end

    it 'prefers native capability limit fields over vendor metadata' do
      deployment[:capabilities].merge!(maxContextToken: '64000', maxOutputToken: '4096')

      runner.refresh

      draft = runner.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.to_h).to include(value: 64_000, source: :provider_catalog)
      expect(draft.max_output_evidence.to_h).to include(value: 4096, source: :provider_catalog)
    end

    it 'preserves an observed positive reasoning flag over the documented negative' do
      deployment[:capabilities][:reasoning] = 'true'

      runner.refresh

      expect(registry.snapshot.each_lane.first.capability_evidence[:thinking].to_h)
        .to include(status: :supported, source: :provider_catalog)
    end

    it 'does not use synthetic top-level limits or malformed native limits as provider facts' do
      deployment[:modelVersion] = 'unknown-version'
      deployment.merge!(context_window: 999_999, max_output_tokens: 999_999)
      deployment[:capabilities].merge!(maxContextToken: '128k', maxOutputToken: '-1')

      runner.refresh

      draft = runner.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.status).to eq(:unknown)
      expect(draft.max_output_evidence.status).to eq(:unknown)
    end

    it 'keeps unknown observed SKUs unknown instead of borrowing GlobalStandard limits' do
      deployment[:sku][:name] = 'UnknownSku'

      runner.refresh

      draft = runner.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.status).to eq(:unknown)
      expect(draft.max_output_evidence.status).to eq(:unknown)
      expect(draft.capability_evidence[:vision].status).to eq(:unknown)
    end
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

  [{ sku: { name: 42 } }, { capabilities: 'invalid' }].each do |invalid|
    it "retains observed offerings after malformed project metadata #{invalid.inspect}" do
      stubs.get(deployment_url) { response(value: [deployment]) }
      stubs.get(resource_url) { response(data: []) }
      runner.refresh
      previous = registry.snapshot.each_lane.map(&:lane_id)
      expect(previous).not_to be_empty

      deployment.merge!(invalid)
      runner.refresh

      expect(registry.snapshot.each_lane.map(&:lane_id)).to eq(previous)
      expect(runner.states.fetch('primary')[:sequence]).to eq(0)
    end
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

  it 'rejects unsupported project API-key configuration rather than treating it as project authentication' do
    tree[:instances][:primary][:credentials][:project_api_key] = 'unsupported-key'

    expect { config }.to raise_error(Legion::Extensions::Llm::ConfigurationError, /project_api_key is unsupported/)
  end

  context 'with an explicitly configured connected resource' do
    let(:resource_url) { 'https://connected.example/openai/v1/models' }
    let(:connection_url) { "#{project_url}/connections/remote?api-version=v1" }
    let(:instance) do
      {
        endpoint: 'https://connected.example', tier: :cloud,
        credentials: { api_key: 'connected-key', project_bearer_token: 'project-token' },
        provider: { surface: :openai_v1, discovery_source: :project,
                    project_endpoint: project_url, project_connection_name: 'remote' }
      }
    end
    let(:connection_info) do
      { name: 'remote', type: 'AzureOpenAI', target: 'https://connected.example',
        credentials: { type: 'ApiKey' } }
    end

    it 'publishes and dispatches the connected deployment through the normal instance callable' do
      stubs.get(deployment_url) do
        response(value: [deployment, deployment.merge(connectionName: 'remote', modelName: 'remote-base'),
                         deployment.merge(connectionName: 'other')])
      end
      stubs.get(connection_url) do |env|
        expect(env.request_headers['Authorization']).to eq('Bearer project-token')
        expect(env.request_headers).not_to have_key('api-key')
        response(**connection_info)
      end
      stubs.get(resource_url) { response(data: []) }
      runner.refresh

      lanes = registry.snapshot.each_lane.to_a
      expect(lanes.map { |lane| [lane.instance_id, lane.model] }).to eq([%w[primary production-chat]])
      expect(lanes.first.metadata[:canonical_model_alias]).to eq('remote-base')
      provider = runner.states.fetch('primary')[:callable]
      provider.connection.connection.adapter(:test, stubs)
      stubs.post('https://connected.example/openai/v1/chat/completions') do |env|
        expect(env.request_headers['api-key']).to eq('connected-key')
        expect(env.request_headers).not_to have_key('Authorization')
        expect(Legion::JSON.load(env.body)[:model]).to eq('production-chat')
        response(model: 'production-chat',
                 choices: [{ message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }])
      end

      result = provider.chat([Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Hello')],
                             model: 'production-chat')
      expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
      stubs.verify_stubbed_calls
    end

    it 'keeps identically named deployments distinct across normal configured instances' do
      tree[:instances][:native] = {
        endpoint: 'https://native.example',
        credentials: { api_key: 'native-key', project_bearer_token: 'project-token' },
        provider: { surface: :openai_v1, discovery_source: :project, project_endpoint: project_url }
      }
      stubs.get(deployment_url) do
        response(value: [deployment, deployment.merge(connectionName: 'remote', modelName: 'remote-base')])
      end
      stubs.get(connection_url) { response(**connection_info) }
      stubs.get(resource_url) { response(data: []) }
      stubs.get('https://native.example/openai/v1/models') { response(data: []) }

      runner.refresh

      lanes = registry.snapshot.each_lane.to_a
      expect(lanes.map { |lane| [lane.instance_id, lane.model] })
        .to contain_exactly(%w[primary production-chat], %w[native production-chat])
      expect(lanes.map(&:callable_handle).uniq.size).to eq(2)
      expect(lanes.to_h { |lane| [lane.instance_id, lane.metadata[:canonical_model_alias]] })
        .to eq('primary' => 'remote-base', 'native' => 'base-model')
      expect(runner.method(:refresh).owner).to eq(Legion::Extensions::Llm::Discovery::Pipeline)
    end

    it 'removes old offerings when a valid connection response points to a different endpoint' do
      target = 'https://connected.example'
      stubs.get(deployment_url) { response(value: [deployment.merge(connectionName: 'remote')]) }
      stubs.get(connection_url) { response(**connection_info, target: target) }
      stubs.get(resource_url) { response(data: []) }
      runner.refresh
      expect(registry.snapshot.each_lane.map(&:model)).to eq(['production-chat'])

      target = 'https://different.example'
      runner.refresh

      expect(registry.snapshot.each_lane.to_a).to be_empty
      expect(runner.states.fetch('primary')[:sequence]).to eq(1)
    end

    it 'retains the last complete snapshot after a connection metadata transport failure' do
      failed = false
      stubs.get(deployment_url) { response(value: [deployment.merge(connectionName: 'remote')]) }
      stubs.get(connection_url) { failed ? response(status: 503, error: 'unavailable') : response(**connection_info) }
      stubs.get(resource_url) { response(data: []) }
      runner.refresh
      previous = registry.snapshot.each_lane.map(&:lane_id)
      expect(previous).not_to be_empty

      failed = true
      runner.refresh

      expect(registry.snapshot.each_lane.map(&:lane_id)).to eq(previous)
      expect(runner.states.fetch('primary')[:sequence]).to eq(0)
    end
  end
end
