# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:message) { Legion::Extensions::Llm::Message.new(role: :user, content: 'brief') }
  let(:chat_model) { Legion::Extensions::Llm::Model::Info.new(id: 'gpt-4o-prod', provider: :azure_foundry) }

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

  it 'exposes provider defaults with offline discovery and inherited fleet settings' do
    expect(default_settings_snapshot).to match(default_settings_matcher)
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:azure_foundry)).to eq(described_class::Provider)
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

  it 'resolves configured aliases back to deployment names' do
    model = described_class::Provider.resolve_model_id('gpt-4o', config: Legion::Extensions::Llm.config)

    expect(model).to eq('gpt-4o-prod')
  end

  it 'reports non-live health without network calls' do
    expect(provider.health(live: false)).to include(provider: :azure_foundry, ready: true, checked: false)
  end

  it 'renders chat payloads through the shared OpenAI-compatible adapter' do
    expect(chat_payload).to include(model: 'gpt-4o-prod',
                                    messages: [{ role: 'user', content: 'brief' }],
                                    stream: true,
                                    temperature: 0.2,
                                    reasoning_effort: 'medium')
  end

  it 'returns a conservative token counting placeholder' do
    expect(provider.count_tokens([message], model: 'gpt-4o-prod'))
      .to include(provider_family: :azure_foundry, model: 'gpt-4o-prod', supported: false,
                  estimated_input_characters: 5)
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

  def default_settings_snapshot
    settings = described_class.default_settings
    {
      provider_family: settings[:provider_family],
      fleet: settings[:fleet],
      live_discovery: settings.dig(:discovery, :live),
      surface: settings.dig(:instances, :default, :surface),
      embedding: settings.dig(:instances, :default, :usage, :embedding)
    }
  end

  def default_settings_matcher
    {
      provider_family: :azure_foundry,
      fleet: include(:enabled),
      live_discovery: false,
      surface: :model_inference,
      embedding: true
    }
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
      chat_capabilities: include(:streaming, :function_calling, :vision),
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

  def expected_model_inference_endpoints
    [
      '/models/chat/completions?api-version=2024-05-01-preview',
      '/models/chat/completions?api-version=2024-05-01-preview',
      '/models/info?api-version=2024-05-01-preview',
      '/models/embeddings?api-version=2024-05-01-preview',
      '/models/info?api-version=2024-05-01-preview'
    ]
  end
end
