# frozen_string_literal: true

require 'spec_helper'

# Regression: Azure Foundry offerings were built WITHOUT limits[:context_window],
# so the router saw azure lanes as unknown/unbounded capacity (cw=nil on
# /api/llm/offerings).
#
# Architecture: each discovered model is offered through the SAME standard
# offering path every other provider uses. context_window flows from the live
# model catalog when the entry reports it (context_window / max_input_tokens /
# context_length), else from the instance-level config (keys :context_window /
# :max_input_tokens). When neither is present the window is simply nil — a
# per-instance gap, never a hardcoded guess.
RSpec.describe 'Legion::Extensions::Llm::AzureFoundry::Provider context window' do
  subject(:provider) { Legion::Extensions::Llm::AzureFoundry::Provider.new(Legion::Extensions::Llm.config) }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.azure_foundry_endpoint = 'https://example.services.ai.azure.com'
      config.azure_foundry_api_key = 'test-key'
      config.azure_foundry_surface = :model_inference
    end
  end

  def stub_catalog(entries)
    allow(provider.connection).to receive(:get).with(provider.models_url).and_return(
      Struct.new(:body).new({ 'data' => entries })
    )
  end

  def offering_for_model(model_id)
    provider.discover_offerings(live: true).find { |o| o.model == model_id }
  end

  context 'when the catalog entry reports an explicit context_window' do
    before do
      stub_catalog([{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o',
                      'context_window' => 128_000, 'max_output_tokens' => 16_384 }])
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

  context 'when the catalog entry reports max_input_tokens instead' do
    before { stub_catalog([{ 'id' => 'custom-llama', 'max_input_tokens' => 32_768 }]) }

    it 'derives a non-nil context_window from max_input_tokens' do
      expect(offering_for_model('custom-llama').context_window).to eq(32_768)
    end
  end

  context 'when the catalog entry reports no context info' do
    before { stub_catalog([{ 'id' => 'private-mystery-model' }]) }

    it 'leaves context_window nil rather than guessing from a hardcoded table' do
      expect(offering_for_model('private-mystery-model').context_window).to be_nil
    end
  end

  context 'when reporting through list_models / Model::Info' do
    before { stub_catalog([{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o', 'context_window' => 128_000 }]) }

    it 'populates Model::Info#context_length so the models API reports it' do
      info = provider.list_models.find { |m| m.id == 'gpt-4o-prod' }

      expect(info.context_length).to eq(128_000)
    end
  end
end
