# frozen_string_literal: true

require 'spec_helper'

# Regression: Azure Foundry offerings were built WITHOUT limits[:context_window],
# so the router saw azure lanes as unknown/unbounded capacity (cw=nil on
# /api/llm/offerings).
#
# Architecture: each Azure deployment/endpoint is discovered as a lane through
# the SAME standard offering path every other provider uses. Azure's own
# inference endpoints (model_inference GET /info, openai_v1 GET /models) do NOT
# report per-model context length, so context_window flows from the discovered
# model catalog when the endpoint provides it, otherwise from the per-deployment
# instance config (keys :context_window / :max_input_tokens). When neither is
# present the window is simply nil — a per-instance gap, never a hardcoded guess.
RSpec.describe Legion::Extensions::Llm::AzureFoundry::Provider do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:provider) { described_class.new(Legion::Extensions::Llm.config) }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.azure_foundry_endpoint = 'https://example.services.ai.azure.com'
      config.azure_foundry_api_key = 'test-key'
      config.azure_foundry_surface = :model_inference
      config.azure_foundry_deployments = deployments
    end
  end

  def offering_for_model(model_id)
    provider.discover_offerings(live: false).find { |o| o.model == model_id }
  end

  context 'when the deployment config declares an explicit context_window' do
    let(:deployments) do
      [{ deployment: 'gpt-4o-prod', canonical_model_alias: 'gpt-4o', usage_type: :inference,
         context_window: 128_000, max_output_tokens: 16_384 }]
    end

    it 'flows context_window into limits (not just metadata)' do
      offering = offering_for_model('gpt-4o-prod')

      expect(offering.limits[:context_window]).to eq(128_000)
      expect(offering.context_window).to eq(128_000)
    end

    it 'flows max_output_tokens into limits when declared' do
      expect(offering_for_model('gpt-4o-prod').limits[:max_output_tokens]).to eq(16_384)
    end
  end

  context 'when the deployment config declares max_input_tokens instead' do
    let(:deployments) do
      [{ deployment: 'custom-llama', usage_type: :inference, max_input_tokens: 32_768 }]
    end

    it 'derives a non-nil context_window from max_input_tokens' do
      expect(offering_for_model('custom-llama').context_window).to eq(32_768)
    end
  end

  context 'when the deployment declares no context info (per-instance gap)' do
    let(:deployments) { [{ deployment: 'private-mystery-model', usage_type: :inference }] }

    it 'leaves context_window nil rather than guessing from a hardcoded table' do
      expect(offering_for_model('private-mystery-model').context_window).to be_nil
    end
  end

  context 'when reporting through list_models / Model::Info' do
    let(:deployments) do
      [{ deployment: 'gpt-4o-prod', canonical_model_alias: 'gpt-4o', usage_type: :inference,
         context_window: 128_000 }]
    end

    it 'populates Model::Info#context_length so the models API reports it' do
      info = provider.list_models.find { |m| m.id == 'gpt-4o-prod' }

      expect(info.context_length).to eq(128_000)
    end
  end

  context 'when a live model catalog reports context length' do
    let(:deployments) { [{ deployment: 'gpt-4o-prod', usage_type: :inference }] }

    it 'sources context_window from the discovered catalog entry' do
      stub_catalog('model_name' => 'gpt-4o-prod', 'context_window' => 200_000)

      offering = provider.discover_offerings(live: true).find { |o| o.model == 'gpt-4o-prod' }

      expect(offering.context_window).to eq(200_000)
    end
  end

  context 'when live discovery runs but the catalog omits context (real Azure behavior)' do
    let(:deployments) do
      [{ deployment: 'gpt-4o-prod', usage_type: :inference, context_window: 128_000 }]
    end

    it 'preserves the config-declared context_window through the live merge' do
      stub_catalog('model_name' => 'gpt-4o-prod', 'model_type' => 'chat_completion')

      offering = provider.discover_offerings(live: true).find { |o| o.model == 'gpt-4o-prod' }

      expect(offering.context_window).to eq(128_000)
    end
  end

  def stub_catalog(body)
    allow(provider.connection).to receive(:get).with(provider.models_url)
                                               .and_return(Struct.new(:body).new(body))
  end
end
