# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:message) { Legion::Extensions::Llm::Message.new(role: :user, content: 'brief') }
  let(:chat_model) { Legion::Extensions::Llm::Model::Info.new(id: 'gpt-4o-prod', provider: :azure_foundry) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.azure_foundry_endpoint = 'https://example.services.ai.azure.com'
      config.azure_foundry_api_key = 'test-key'
      config.azure_foundry_bearer_token = nil
      config.azure_foundry_api_version = '2024-05-01-preview'
      config.azure_foundry_surface = :model_inference
      config.azure_foundry_deployments = configured_deployments
    end
  end

  it 'exposes provider defaults through the shared provider settings shape' do
    expect(default_settings_snapshot).to match(default_settings_matcher)
  end

  it 'exposes the provider class' do
    expect(described_class.provider_class).to eq(described_class::Provider)
  end

  it 'delegates registry_publisher to the base RegistryPublisher' do
    publisher = described_class.registry_publisher

    expect(publisher).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(publisher.provider_family).to eq(:azure_foundry)
  end

  it 'exposes Azure AI Foundry model inference endpoint helpers' do
    expect(provider.api_base).to eq('https://example.services.ai.azure.com')
    expect(provider.headers).to include('api-key' => 'test-key')
    expect(endpoint_helpers).to eq(expected_model_inference_endpoints)
  end

  it 'can target the OpenAI v1-compatible Azure surface' do
    Legion::Extensions::Llm.config.azure_foundry_surface = :openai_v1
    Legion::Extensions::Llm.config.azure_foundry_endpoint = 'https://example.openai.azure.com'

    expect(provider.api_base).to eq('https://example.openai.azure.com/openai/v1')
    expect([provider.chat_url, provider.embedding_url(model: 'text-embedding')])
      .to eq(['/chat/completions', '/embeddings'])
  end

  it 'maps configured deployments to Azure Foundry routing offerings without live calls' do
    expect(offering_snapshot).to match(offering_matcher)
  end

  it 'preserves deployment names while requiring explicit metadata when the base model cannot be proven' do
    offering = provider.offering_for(model: 'private-mistral-eastus', model_family: :mistral)

    expect(offering.to_h).to include(provider_family: :azure_foundry, model: 'private-mistral-eastus')
    expect(offering.metadata).to include(model_family: :mistral, requires_explicit_model_metadata: true)
  end

  it 'uses provider instance transport, tier, and instance id in offerings' do
    expect(configured_transport_offering.to_h).to include(transport: :rabbitmq, tier: :fleet, instance_id: :eastus)
  end

  it 'resolves configured aliases back to deployment names' do
    model = described_class::Provider.resolve_model_id('gpt-4o', config: Legion::Extensions::Llm.config)

    expect(model).to eq('gpt-4o-prod')
  end

  it 'reports non-live health without network calls' do
    expect(offline_health).to include(offline_health_matcher)
  end

  it 'publishes live readiness metadata asynchronously through the registry publisher' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(provider.connection).to receive(:get).with(provider.health_url).and_return(fake_response({}))
    allow(registry_publisher).to receive(:publish_readiness_async)

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'publishes configured deployment models asynchronously through the registry publisher' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)

    models = provider.list_models

    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :azure_foundry, live: false))
  end

  it 'builds sanitized lex-llm registry events for Azure Foundry model availability' do
    model = provider.list_models.first
    events = capture_registry_events([model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:azure_foundry)
    expect(events.first.to_h.dig(:offering, :model)).to eq('gpt-4o-prod')
  end

  it 'renders chat payloads through the shared OpenAI-compatible adapter' do
    expect(chat_payload).to include(model: 'gpt-4o-prod',
                                    messages: [{ role: 'user', content: 'brief' }],
                                    stream: true,
                                    temperature: 0.2,
                                    reasoning_effort: 'medium')
  end

  it 'returns a conservative token counting placeholder' do
    expect(provider.count_tokens(messages: [message], model: 'gpt-4o-prod'))
      .to include(provider_family: :azure_foundry, model: 'gpt-4o-prod', supported: false,
                  estimated_input_characters: 5)
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(nil)
    end

    it 'returns an empty hash when no settings are configured' do
      expect(described_class.discover_instances).to eq({})
    end

    it 'discovers a :settings instance when endpoint is present' do # rubocop:disable RSpec/ExampleLength
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ endpoint: 'https://my.azure.com', api_key: 'ak-123' })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(azure_foundry_endpoint: 'https://my.azure.com',
                                              azure_foundry_api_key: 'ak-123',
                                              tier: :cloud)
      expect(instances[:settings]).not_to have_key(:endpoint)
    end

    it 'preserves an explicit tier for the default discovered instance' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ endpoint: 'https://my.azure.com', api_key: 'ak-123', tier: :private })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(tier: :private)
    end

    it 'skips the default instance when endpoint is missing' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ api_key: 'ak-123' })

      instances = described_class.discover_instances

      expect(instances).not_to have_key(:settings)
    end

    it 'discovers named instances from the instances sub-key' do # rubocop:disable RSpec/ExampleLength
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ instances: { prod: { endpoint: 'https://prod.azure.com', api_key: 'ak-prod' } } })

      instances = described_class.discover_instances

      expect(instances[:prod]).to include(azure_foundry_endpoint: 'https://prod.azure.com',
                                          azure_foundry_api_key: 'ak-prod',
                                          tier: :cloud)
    end

    it 'preserves an explicit tier for named instances' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ instances: { prod: { endpoint: 'https://prod.azure.com', api_key: 'ak-prod', tier: :fleet } } })

      instances = described_class.discover_instances

      expect(instances[:prod]).to include(tier: :fleet)
    end

    it 'normalizes endpoint aliases and deployment settings' do # rubocop:disable RSpec/ExampleLength
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ base_url: 'https://openai.azure.com', api_key: 'ak-123',
                      api_version: '2024-05-01-preview', deployments: ['gpt-4o'] })

      expect(described_class.discover_instances[:settings]).to include(
        azure_foundry_endpoint: 'https://openai.azure.com',
        azure_foundry_api_key: 'ak-123',
        azure_foundry_api_version: '2024-05-01-preview',
        azure_foundry_deployments: ['gpt-4o']
      )
    end

    it 'skips named instances without an endpoint' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ instances: { incomplete: { api_key: 'ak-no-ep' } } })

      instances = described_class.discover_instances

      expect(instances).not_to have_key(:incomplete)
    end

    it 'excludes the instances sub-key from the default instance config' do
      cfg = { endpoint: 'https://main.azure.com', instances: { extra: { endpoint: 'https://extra.azure.com' } } }
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry).and_return(cfg)

      expect(described_class.discover_instances[:settings]).not_to have_key(:instances)
    end
  end

  def default_settings_snapshot
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)
    {
      enabled: settings[:enabled],
      provider_family: settings[:provider_family],
      endpoint: instance[:endpoint],
      api_version: instance.dig(:provider, :api_version),
      surface: instance.dig(:provider, :surface),
      deployments: instance.dig(:provider, :deployments),
      fleet: instance[:fleet],
      usage: instance[:usage]
    }
  end

  def default_settings_matcher
    {
      enabled: true,
      provider_family: :azure_foundry,
      endpoint: nil,
      api_version: '2024-05-01-preview',
      surface: nil,
      deployments: [],
      fleet: hash_including(enabled: false, respond_to_requests: false, capabilities: %i[chat stream_chat embed tools]),
      usage: hash_including(inference: true, embedding: true)
    }
  end

  def configured_deployments
    [
      {
        deployment: 'gpt-4o-prod',
        model_family: :openai,
        canonical_model_alias: 'gpt-4o',
        usage_type: :inference
      },
      {
        deployment: 'embedding-prod',
        model_family: :openai,
        canonical_model_alias: 'text-embedding-3-small',
        usage_type: :embedding
      }
    ]
  end

  def offering_snapshot
    offerings = provider.discover_offerings(live: false)
    chat = offerings.find { |offering| offering.model == 'gpt-4o-prod' }
    embedding = offerings.find(&:embedding?)
    {
      provider_family: chat.provider_family,
      chat_metadata: chat.metadata,
      chat_capabilities: chat.capabilities,
      embedding_metadata: embedding.metadata,
      embedding_usage_type: embedding.usage_type
    }
  end

  def offering_matcher
    {
      provider_family: :azure_foundry,
      chat_metadata: include(model_family: :openai, canonical_model_alias: 'gpt-4o'),
      chat_capabilities: include(:streaming, :tools, :vision),
      embedding_metadata: include(model_family: :openai, canonical_model_alias: 'text-embedding-3-small'),
      embedding_usage_type: :embedding
    }
  end

  def chat_payload
    provider.send(:render_payload, [message], tools: {}, temperature: 0.2, model: chat_model, stream: true,
                                              schema: nil, thinking: { effort: 'medium' }, tool_prefs: nil)
  end

  def endpoint_helpers
    [
      provider.chat_url,
      provider.stream_url,
      provider.models_url,
      provider.embedding_url(model: 'embedding-prod'),
      provider.health_url
    ]
  end

  def offline_health
    provider.health(live: false)
  end

  def offline_health_matcher
    {
      provider: :azure_foundry,
      instance_id: :default,
      ready: true,
      checked: false,
      status: 'healthy',
      circuit_state: 'closed'
    }
  end

  def configured_transport_offering
    described_class::Provider.new(
      azure_foundry_endpoint: 'https://example.services.ai.azure.com',
      azure_foundry_api_key: 'test-key',
      azure_foundry_deployments: configured_deployments,
      instance_id: :eastus,
      transport: :rabbitmq,
      tier: :fleet
    ).offering_for(model: 'private-mistral-eastus', model_family: :mistral)
  end

  def expected_model_inference_endpoints
    [
      '/models/chat/completions?api-version=2024-05-01-preview',
      '/models/chat/completions?api-version=2024-05-01-preview',
      '/models/info?api-version=2024-05-01-preview',
      '/models/embeddings?api-version=2024-05-01-preview',
      '/models/info?api-version=2024-05-01-preview'
    ]
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def capture_registry_events(models, readiness:)
    publisher = Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :azure_foundry)
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
