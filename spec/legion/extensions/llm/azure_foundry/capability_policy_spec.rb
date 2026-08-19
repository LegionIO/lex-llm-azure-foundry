# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Extensions::Llm::AzureFoundry::Provider capability policy' do
  subject(:provider) { Legion::Extensions::Llm::AzureFoundry::Provider.new(Legion::Extensions::Llm.config) }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.azure_foundry_endpoint = 'https://example.services.ai.azure.com'
      config.azure_foundry_api_key = 'test-key'
      config.azure_foundry_surface = :model_inference
    end
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :azure_foundry).and_return(provider_settings)
  end

  def stub_catalog(entries)
    allow(provider.connection).to receive(:get).with(provider.models_url).and_return(
      Struct.new(:body).new({ 'data' => entries })
    )
  end

  describe 'CapabilityPolicy integration' do
    context 'when the catalog entry has no feature metadata' do
      let(:provider_settings) { { endpoint: 'https://example.services.ai.azure.com' } }

      before { stub_catalog([{ 'id' => 'unknown-model-v1' }]) }

      it 'defaults all optional capabilities to false except streaming and tools from real metadata' do
        offering = provider.discover_offerings(live: true).find { |o| o.model == 'unknown-model-v1' }

        expect(offering.capability_sources[:vision]).to include(value: false)
        expect(offering.capability_sources[:thinking]).to include(value: false, source: :default_false)
        expect(offering.capability_sources[:structured_output]).to include(value: false, source: :default_false)
      end
    end

    context 'with provider-root override' do
      before { stub_catalog([{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o' }]) }

      let(:provider_settings) do
        { endpoint: 'https://example.services.ai.azure.com', streaming_flag: true, tools_flag: false }
      end

      it 'applies streaming as :provider_override' do
        offering = first_offering

        expect(offering.capability_sources[:streaming]).to include(value: true, source: :provider_override)
        expect(offering.capabilities).to include(:streaming)
      end

      it 'applies tools_flag false as :provider_override' do
        offering = first_offering

        expect(offering.capability_sources[:tools]).to include(value: false, source: :provider_override)
        expect(offering.capabilities).not_to include(:tools)
      end
    end

    context 'with instance override' do
      before { stub_catalog([{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o' }]) }

      let(:provider_settings) { { endpoint: 'https://example.services.ai.azure.com' } }

      it 'applies tools as :instance_override and embedding_flag false as :instance_override' do
        configured = build_configured_provider
        offering = configured.discover_offerings(live: true).find { |o| o.model == 'gpt-4o-prod' }

        expect(offering.capability_sources[:tools]).to include(value: true, source: :instance_override)
        expect(offering.capability_sources[:embedding]).to include(value: false, source: :instance_override)
      end
    end

    context 'with model override' do
      before { stub_catalog([{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o' }]) }

      let(:provider_settings) do
        { endpoint: 'https://example.services.ai.azure.com',
          models: { 'gpt-4o-prod': { tools_flag: false, vision_flag: true } } }
      end

      it 'applies tools false as :model_override' do
        offering = first_offering

        expect(offering.capability_sources[:tools]).to include(value: false, source: :model_override)
        expect(offering.capabilities).not_to include(:tools)
      end

      it 'applies vision true as :model_override' do
        offering = first_offering

        expect(offering.capability_sources[:vision]).to include(value: true, source: :model_override)
        expect(offering.capabilities).to include(:vision)
      end
    end
  end

  def build_configured_provider
    p = Legion::Extensions::Llm::AzureFoundry::Provider.new(
      azure_foundry_endpoint: 'https://example.services.ai.azure.com',
      azure_foundry_api_key: 'test-key',
      azure_foundry_surface: :model_inference,
      tools_flag: true,
      embedding_flag: false
    )
    allow(p.connection).to receive(:get).with(p.models_url).and_return(
      Struct.new(:body).new({ 'data' => [{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o' }] })
    )
    p
  end

  def first_offering
    provider.discover_offerings(live: true).find { |o| o.model == 'gpt-4o-prod' }
  end
end
