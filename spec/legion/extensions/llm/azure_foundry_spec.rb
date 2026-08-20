# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::AzureFoundry do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:message) { Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'brief') }

  before do
    Legion::Extensions::Llm::Inventory::Registry.reset!
    Legion::Extensions::Llm.configure do |config|
      config.azure_foundry_endpoint = 'https://example.services.ai.azure.com'
      config.azure_foundry_api_key = 'test-key'
      config.azure_foundry_bearer_token = nil
      config.azure_foundry_api_version = '2024-05-01-preview'
      config.azure_foundry_surface = :model_inference
    end
    stub_catalog
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
      .to eq(['chat/completions', 'embeddings'])
  end

  it 'lists and health-checks the OpenAI v1 surface at /models, not the model-inference /info route' do
    Legion::Extensions::Llm.config.azure_foundry_surface = :openai_v1
    Legion::Extensions::Llm.config.azure_foundry_endpoint = 'https://example.openai.azure.com'

    expect([provider.models_url, provider.health_url]).to eq(%w[models models])
  end

  # Regression: Faraday::Connection is built with the endpoint (which carries the
  # /openai/v1 path on this surface) as the base, then given each helper path. A
  # LEADING slash makes Faraday treat the path as absolute and DROP /openai/v1,
  # yielding 404s on discovery and chat. Paths must be relative so the base path
  # survives. This asserts the fully composed URL the daemon actually requests.
  it 'composes full OpenAI v1 URLs that preserve the /openai/v1 base path' do
    configure_openai_v1_surface
    expect(composed_openai_v1_urls).to eq(expected_openai_v1_urls)
  end

  # Read path (07 C5): discover_offerings serves the activated inventory
  # offerings from the Registry snapshot; the discovery actor's writer is the
  # sole publication path (live catalog -> OfferingDraft -> Registry).
  it 'serves the writer-published inventory offerings from the Registry snapshot' do
    publish_default_instance
    offerings = provider.discover_offerings(live: true)
    chat = offerings.find { |offering| offering.model == 'gpt-4o-prod' }
    embedding = offerings.find { |offering| offering.operation_status(operation: :embed) == :supported }

    expect(offerings).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingRecord))
    expect(chat.instance_key.provider_family).to eq(:azure_foundry)
    expect(chat.metadata[:canonical_model_alias]).to eq('gpt-4o')
    expect(chat.capability_status(capability: :streaming)).to eq(:supported)
    expect(chat.capability_status(capability: :tools)).to eq(:supported)
    expect(embedding.metadata[:canonical_model_alias]).to eq('text-embedding-3-small')
    expect(embedding.operation_status(operation: :chat)).to eq(:unsupported)
  end

  it 'preserves catalog-reported names and infers family from the base model' do
    publish_default_instance
    offering = provider.discover_offerings(live: true).find { |offering| offering.model == 'gpt-4o-prod' }

    expect(offering.instance_key.provider_family).to eq(:azure_foundry)
    expect(offering.model).to eq('gpt-4o-prod')
    expect(offering.metadata).to include(model_family: :openai)
  end

  it 'uses the provider instance tier and instance id in the published offerings' do
    publish_instance(instance_id: 'eastus', tier: :fleet)
    offering = configured_transport_provider.discover_offerings(live: true).first

    expect(offering.tier).to eq(:fleet)
    expect(offering.instance_key.instance_id).to eq('eastus')
  end

  it 'reports non-live health without network calls' do
    expect(offline_health).to include(offline_health_matcher)
  end

  it 'returns live readiness metadata including provider' do
    allow(provider.connection).to receive(:get).with(provider.health_url).and_return(fake_response({}))

    readiness = provider.readiness(live: true)

    expect(readiness).to include(provider: :azure_foundry, live: true, local: false, remote: true)
    expect(readiness).to include(ready: true, status: 'healthy')
    expect(readiness).not_to have_key(:circuit_state)
  end

  it 'returns an array of Model::Info instances from list_models' do
    models = provider.list_models

    expect(models).to be_an(Array)
    expect(models).to all(be_a(Legion::Extensions::Llm::Model::Info))
    expect(models.map(&:provider)).to all(eq(:azure_foundry))
    expect(models.map(&:id)).to eq(%w[gpt-4o-prod embedding-prod])
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

  it 'renders the Selection-derived model to the wire untouched (no re-derivation)' do
    expect(chat_payload[:model]).to eq('gpt-4o-prod')
  end

  # 05 §2: count_tokens returns the base heuristic Integer estimate. Azure
  # has no portable counting endpoint — the support signal lives in the SSOT
  # data plane (writer operation evidence), not in a per-call artifact.
  it 'returns the base heuristic Integer estimate for canonical messages' do
    # 'brief' = 5 characters -> ceil(5 / 4) = 2 estimated tokens.
    expect(provider.count_tokens(messages: [message], model: 'gpt-4o-prod')).to eq(2)
  end

  # Dispatch boundary regression (N x N law, 08 F2, kit B1): pipeline
  # dispatch delivers Canonical::Message objects and nothing else. Plain
  # Hashes are the bypass class — the lenient hash tolerance is what masked
  # the 2026-08-19 incident. Every message-operation entry runs the shared
  # lex-llm enforce helper and rejects non-canonical shapes loudly.
  describe 'canonical dispatch boundary (N x N law)' do
    let(:hash_messages) { [{ role: 'user', content: 'hi' }] }
    let(:canonical_messages) do
      [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]
    end

    it 'rejects plain Hash messages at chat' do
      expect { provider.chat(hash_messages, model: 'gpt-4o') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'rejects plain Hash messages at stream' do
      expect { provider.stream(hash_messages, model: 'gpt-4o') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'rejects plain Hash messages at count_tokens' do
      expect { provider.count_tokens(messages: hash_messages, model: 'gpt-4o') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'passes canonical messages through chat to the wire payload and returns a Canonical::Response' do
      captured = []
      allow(provider.connection).to receive(:post) do |_url, payload|
        captured << payload
        fake_response({
                        'model' => 'gpt-4o-prod',
                        'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => 'ok' } }],
                        'usage' => { 'prompt_tokens' => 1, 'completion_tokens' => 1 }
                      })
      end

      response = provider.chat(canonical_messages, model: 'gpt-4o-prod')
      expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)

      expect(captured.map { |payload| payload[:messages] })
        .to all(eq([{ role: 'user', content: 'hi' }]))
    end
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(nil)
    end

    it 'returns an empty hash when no settings are configured' do
      expect(described_class.discover_instances).to eq({})
    end

    it 'discovers a :settings instance when endpoint is present' do
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

    it 'discovers named instances from the instances sub-key' do
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

    it 'normalizes endpoint aliases and API version settings' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ base_url: 'https://openai.azure.com', api_key: 'ak-123',
                      api_version: '2024-05-01-preview' })

      expect(described_class.discover_instances[:settings]).to include(
        azure_foundry_endpoint: 'https://openai.azure.com',
        azure_foundry_api_key: 'ak-123',
        azure_foundry_api_version: '2024-05-01-preview'
      )
    end

    it 'resolves the canonical nested credentials and provider shape' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :azure_foundry)
        .and_return({ instances: { shrutich: {
                      endpoint: 'https://shrutich.openai.azure.com/openai/v1',
                      credentials: { api_key: 'ak-nested', bearer_token: 'bt-nested' },
                      provider: { surface: 'openai_v1', api_version: '2024-05-01-preview' }
                    } } })

      expect(described_class.discover_instances[:shrutich]).to include(
        azure_foundry_endpoint: 'https://shrutich.openai.azure.com/openai/v1',
        azure_foundry_api_key: 'ak-nested',
        azure_foundry_bearer_token: 'bt-nested',
        azure_foundry_surface: 'openai_v1',
        azure_foundry_api_version: '2024-05-01-preview'
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
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(cfg)

      expect(described_class.discover_instances[:settings]).not_to have_key(:instances)
    end
  end

  def stub_catalog(entries = default_catalog_entries)
    allow(provider.connection).to receive(:get).with(provider.models_url).and_return(
      fake_response({ 'data' => entries })
    )
  end

  def default_catalog_entries
    [
      { 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o', 'context_window' => 128_000,
        'max_output_tokens' => 16_384 },
      { 'id' => 'embedding-prod', 'model_name' => 'text-embedding-3-small' }
    ]
  end

  def configured_transport_provider
    p = described_class::Provider.new(
      azure_foundry_endpoint: 'https://example.services.ai.azure.com',
      azure_foundry_api_key: 'test-key',
      instance_id: :eastus,
      transport: :rabbitmq,
      tier: :fleet
    )
    allow(p.connection).to receive(:get).with(p.models_url).and_return(
      fake_response({ 'data' => default_catalog_entries })
    )
    p
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
      fleet: hash_including(enabled: false, respond_to_requests: false, capabilities: %i[chat stream_chat embed tools]),
      usage: hash_including(inference: true, embedding: true)
    }
  end

  # 08 R1 render boundary: canonical inputs in (model String, Canonical::Params,
  # Canonical::Thinking::Config), provider wire out.
  def chat_payload
    params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2)
    thinking = Legion::Extensions::Llm::Canonical::Thinking::Config.build(effort: 'medium')
    provider.send(:render_payload, [message], tools: {}, model: 'gpt-4o-prod', stream: true,
                                              schema: nil, thinking:, params:, tool_prefs: nil)
  end

  # Publishes the default catalog through the production writer path
  # (discovery actor draft builder + Inventory::Publisher) under the given
  # instance id, so the base Registry-snapshot read path has offerings to
  # serve.
  def publish_instance(instance_id: 'default', tier: :cloud)
    instance_cfg = {
      azure_foundry_endpoint: 'https://example.services.ai.azure.com',
      azure_foundry_api_key: 'test-key',
      tier:
    }
    key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry, instance_id:
    )
    actor = Legion::Extensions::Llm::AzureFoundry::Actor::DiscoveryRefresh.new
    publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
    callable = Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable.new(
      instance_cfg:, logger: Logger.new(File::NULL)
    )
    coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
      instance_key: key, enqueue: ->(**) { true }
    )
    token = publisher.claim_instance(instance_id:, callable:, probe_request_handle: coordinator)
    probe = publisher.readiness_probe_started(instance_id:, publisher_token: token)
    drafts = actor.send(:build_offering_drafts, entries: default_catalog_entries,
                                                instance_cfg:, instance_key: key)
    publisher.activate_instance_snapshot(instance_id:, publisher_token: token, offerings: drafts,
                                         sequence: 0, probe_token: probe)
  end

  def publish_default_instance = publish_instance

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
      ready: true,
      checked: false,
      status: 'healthy'
    }
  end

  def expected_model_inference_endpoints
    [
      'models/chat/completions?api-version=2024-05-01-preview',
      'models/chat/completions?api-version=2024-05-01-preview',
      'models/info?api-version=2024-05-01-preview',
      'models/embeddings?api-version=2024-05-01-preview',
      'models/info?api-version=2024-05-01-preview'
    ]
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def configure_openai_v1_surface
    Legion::Extensions::Llm.config.azure_foundry_surface = :openai_v1
    Legion::Extensions::Llm.config.azure_foundry_endpoint = 'https://example.openai.azure.com'
  end

  def composed_openai_v1_urls
    conn = Faraday.new(provider.api_base)
    [provider.chat_url, provider.models_url, provider.embedding_url(model: 'text-embedding')]
      .map { |path| conn.build_url(path).to_s }
  end

  def expected_openai_v1_urls
    [
      'https://example.openai.azure.com/openai/v1/chat/completions',
      'https://example.openai.azure.com/openai/v1/models',
      'https://example.openai.azure.com/openai/v1/embeddings'
    ]
  end

  def capture_registry_events(models, readiness:)
    publisher = Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :azure_foundry)
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(publisher).to receive(:schedule).and_yield
    publisher.publish_models_async(models, readiness:)
    events
  end
end
