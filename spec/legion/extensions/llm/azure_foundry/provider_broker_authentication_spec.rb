# frozen_string_literal: true

require 'spec_helper'
require 'legion/identity/lease'
require 'legion/identity/lease_renewer'
require 'legion/identity/broker'
require 'legion/extensions/llm/azure_foundry/runners/discovery'
require_relative '../../../../support/broker_issuer'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Provider do
  let(:broker) { Legion::Identity::Broker }
  let(:runner) { Legion::Extensions::Llm::AzureFoundry::Runners::Discovery }
  let(:reference) { { provider: 'entra_delegated', qualifier: 'azure-resource' } }
  let(:provider_config) do
    { azure_foundry_endpoint: 'https://resource.example', azure_foundry_surface: :openai_v1,
      azure_foundry_broker: reference }
  end

  def register_token(token:, qualifier: :'azure-resource', expires_at: nil)
    lease = Legion::Identity::Lease.new(provider: :entra_delegated, credential: token, expires_at: expires_at)
    issuer = AzureBrokerIssuer.new(lease: lease)
    broker.register_provider(:entra_delegated, provider: issuer, lease: lease, qualifier: qualifier)
  end

  before do
    broker.reset!
    Legion::Extensions::Llm::Inventory::Registry.reset!
    runner.reset_state!
    Legion::Settings[:extensions][:llm] = { azure_foundry: Legion::Extensions::Llm::AzureFoundry.default_settings }
  end

  after do
    runner.remove_all_instances
    runner.reset_state!
    Legion::Extensions::Llm::Inventory::Registry.reset!
    broker.reset!
  end

  it 'reads the current broker lease for each request on a persistent provider' do
    register_token(token: 'first-resource-token')
    provider = described_class.new(provider_config)
    expect(provider.headers['Authorization']).to eq('Bearer first-resource-token')

    register_token(token: 'renewed-resource-token')

    expect(provider.headers['Authorization']).to eq('Bearer renewed-resource-token')
  end

  it 'does not fall back to the default Graph lease when the configured qualifier is unavailable' do
    register_token(token: 'graph-token', qualifier: :delegated)
    provider = described_class.new(provider_config)

    expect { provider.headers }.to raise_error(Legion::Extensions::Llm::UnauthorizedError, /broker credential/)
  end

  it 'observes renewal performed by the host LeaseRenewer without a provider-local token cache' do
    first = Legion::Identity::Lease.new(provider: :entra_delegated, credential: 'lease-one',
                                        expires_at: Time.now + 300, renewable: true)
    issuer = AzureBrokerIssuer.new(lease: first)
    broker.register_provider(:entra_delegated, provider: issuer, lease: first, qualifier: :'azure-resource')
    provider = described_class.new(provider_config)
    expect(provider.headers['Authorization']).to eq('Bearer lease-one')

    issuer.lease = Legion::Identity::Lease.new(provider: :entra_delegated, credential: 'lease-two',
                                               expires_at: Time.now + 300, renewable: true)
    broker.renewer_for(:entra_delegated, qualifier: :'azure-resource').send(:renew)

    expect(provider.headers['Authorization']).to eq('Bearer lease-two')
  end

  it 'rejects an expired lease instead of sending stale authorization' do
    register_token(token: 'expired', expires_at: Time.now - 60)

    expect { described_class.new(provider_config).headers }
      .to raise_error(Legion::Extensions::Llm::UnauthorizedError, /broker credential/)
  end

  it 'rejects ambiguous static and broker sources without selecting a fallback' do
    provider = described_class.new(provider_config.merge(azure_foundry_api_key: 'configured-key'))

    expect { provider.headers }.to raise_error(Legion::Extensions::Llm::ConfigurationError, /exactly one/)
  end

  it 'keeps broker-configured instances discoverable while a lease is temporarily absent' do
    tree = Legion::Settings[:extensions][:llm][:azure_foundry]
    tree[:instances] = {
      primary: { endpoint: 'https://resource.example', credentials: { broker: reference },
                 provider: { surface: :openai_v1 } }
    }

    expect(Legion::Extensions::Llm::AzureFoundry.discover_instances.keys).to eq([:primary])
  end

  it 'refreshes authorization between project pages and never forwards resource credentials' do
    register_token(token: 'project-one', qualifier: :'azure-project')
    cfg = provider_config.except(:azure_foundry_broker).merge(
      azure_foundry_api_key: 'resource-key',
      azure_foundry_project_endpoint: 'https://project.example/api/projects/p',
      azure_foundry_project_api_version: 'v1',
      azure_foundry_project_broker: { provider: 'entra_delegated', qualifier: 'azure-project' }
    )
    stubs = Faraday::Adapter::Test::Stubs.new
    page = 'https://project.example/api/projects/p/deployments?api-version=v1'
    stubs.get(page) do |env|
      expect(env.request_headers['Authorization']).to eq('Bearer project-one')
      expect(env.request_headers).not_to have_key('api-key')
      register_token(token: 'project-two', qualifier: :'azure-project')
      [200, {}, Legion::JSON.dump({ value: [], nextLink: "#{page}&skip=1" })]
    end
    stubs.get("#{page}&skip=1") do |env|
      expect(env.request_headers['Authorization']).to eq('Bearer project-two')
      expect(env.request_headers).not_to have_key('api-key')
      [200, {}, Legion::JSON.dump({ value: [] })]
    end
    allow(runner).to receive(:build_connection).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap { |connection| connection.adapter(:test, stubs) }
    end

    expect(runner.fetch_raw_models(instance_cfg: cfg)).to eq([])
    stubs.verify_stubbed_calls
  end

  it 'reuses the callable on lease renewal but reclaims it when the broker binding changes' do
    tree = Legion::Settings[:extensions][:llm][:azure_foundry]
    tree[:instances] = { primary: { endpoint: 'https://resource.example', credentials: { broker: reference } } }
    register_token(token: 'first-resource-token')
    stubs = Faraday::Adapter::Test::Stubs.new
    seen = []
    stubs.get('https://resource.example/models/info?api-version=2024-05-01-preview') do |env|
      seen << env.request_headers['Authorization']
      [200, {}, Legion::JSON.dump({ model_name: 'deployment', model_type: 'chat-completion' })]
    end
    allow(runner).to receive(:build_connection).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap { |connection| connection.adapter(:test, stubs) }
    end
    runner.refresh
    original = runner.states.fetch('primary')[:callable]
    expect(original.headers['Authorization']).to eq('Bearer first-resource-token')

    register_token(token: 'renewed-resource-token')
    runner.refresh

    expect(runner.states.fetch('primary')[:callable]).to equal(original)
    expect(original.headers['Authorization']).to eq('Bearer renewed-resource-token')
    expect(seen).to include('Bearer first-resource-token', 'Bearer renewed-resource-token')

    register_token(token: 'different-source-token', qualifier: :'second-resource')
    tree[:instances][:primary][:credentials][:broker][:qualifier] = 'second-resource'
    expect(original.headers['Authorization']).to eq('Bearer renewed-resource-token')
    runner.refresh

    replacement = runner.states.fetch('primary')[:callable]
    expect(replacement).not_to equal(original)
    expect(replacement.headers['Authorization']).to eq('Bearer different-source-token')

    static = +'static-one'
    tree[:instances][:primary][:credentials].delete(:broker)
    tree[:instances][:primary][:credentials][:bearer_token] = static
    runner.refresh
    static_provider = runner.states.fetch('primary')[:callable]
    static.replace('static-two')
    expect(static_provider.headers['Authorization']).to eq('Bearer static-one')
    runner.refresh
    expect(runner.states.fetch('primary')[:callable].headers['Authorization']).to eq('Bearer static-two')
  end

  it 'requires an explicit broker qualifier and never selects a default implicitly' do
    config = provider_config.merge(azure_foundry_broker: { provider: 'entra_delegated' })

    expect { described_class.new(config).headers }
      .to raise_error(Legion::Extensions::Llm::ConfigurationError, /qualifier must be explicit/)
  end
end
