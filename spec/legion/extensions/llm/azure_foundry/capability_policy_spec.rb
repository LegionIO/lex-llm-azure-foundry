# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Provider do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:provider) { described_class.new(Legion::Extensions::Llm.config) }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.azure_foundry_endpoint = 'https://example.services.ai.azure.com'
      config.azure_foundry_api_key = 'test-key'
      config.azure_foundry_surface = :model_inference
      config.azure_foundry_deployments = deployments
    end
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :azure_foundry).and_return(provider_settings)
  end

  describe 'CapabilityPolicy integration' do
    context 'when deployment has no feature metadata' do
      let(:deployments) { [{ deployment: 'unknown-model-v1', usage_type: :inference }] }
      let(:provider_settings) { { endpoint: 'https://example.services.ai.azure.com' } }

      it 'defaults all optional capabilities to false except streaming and tools from real metadata' do
        offerings = provider.discover_offerings(live: false)
        offering = offerings.find { |o| o.model == 'unknown-model-v1' }

        expect(offering.capability_sources[:vision]).to include(value: false)
        expect(offering.capability_sources[:thinking]).to include(value: false, source: :default_false)
        expect(offering.capability_sources[:structured_output]).to include(value: false, source: :default_false)
      end
    end

    context 'with provider-root override' do
      let(:deployments) { [{ deployment: 'gpt-4o-prod', model_family: :openai, usage_type: :inference }] }
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
      let(:deployments) { [{ deployment: 'gpt-4o-prod', model_family: :openai, usage_type: :inference }] }
      let(:provider_settings) { { endpoint: 'https://example.services.ai.azure.com' } }

      it 'applies tools as :instance_override and embedding_flag false as :instance_override' do # rubocop:disable RSpec/ExampleLength
        configured = described_class.new(
          azure_foundry_endpoint: 'https://example.services.ai.azure.com',
          azure_foundry_api_key: 'test-key',
          azure_foundry_surface: :model_inference,
          azure_foundry_deployments: deployments,
          tools_flag: true,
          embedding_flag: false
        )
        offering = configured.discover_offerings(live: false).find { |o| o.model == 'gpt-4o-prod' }

        expect(offering.capability_sources[:tools]).to include(value: true, source: :instance_override)
        expect(offering.capability_sources[:embeddings]).to include(value: false, source: :instance_override)
      end
    end

    context 'with model override' do
      let(:deployments) { [{ deployment: 'gpt-4o-prod', model_family: :openai, usage_type: :inference }] }
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

  def first_offering
    provider.discover_offerings(live: false).find { |o| o.model == 'gpt-4o-prod' }
  end
end
