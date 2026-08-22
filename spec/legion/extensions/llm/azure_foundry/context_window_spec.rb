# frozen_string_literal: true

require 'spec_helper'

# The runner is NOT on the default require path outside the daemon — explicit.
require 'legion/extensions/llm/azure_foundry/runners/discovery'

# Regression: Azure Foundry lanes were published WITHOUT a context window,
# so the router saw azure lanes as unknown/unbounded capacity (cw=nil on
# /api/llm/offerings).
#
# Architecture (07 C1-C5): each discovered model is published through the
# discovery runner's writer path, which carries the context window as
# context_evidence (ValueEvidence). The value flows from the live model
# catalog when the entry reports it (context_window / max_input_tokens /
# context_length), else from the instance-level config (keys :context_window /
# :max_input_tokens). When neither is present the window is simply unknown —
# a per-instance gap, never a hardcoded guess.
RSpec.describe 'Legion::Extensions::Llm::AzureFoundry context window evidence' do
  # The production writer seam: the discovery runner's own draft builder with
  # harness-supplied catalog entries (no network involved).
  def draft_for_model(model_id, entries, instance_cfg: {})
    runner = Legion::Extensions::Llm::AzureFoundry::Runners::Discovery
    key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry, instance_id: 'context-window-spec'
    )
    cfg = {
      azure_foundry_endpoint: 'https://ctx.example.services.ai.azure.com',
      azure_foundry_api_key: 'ak-ctx-spec'
    }.merge(instance_cfg)
    drafts = entries.filter_map do |entry|
      runner.send(:build_offering_draft, instance_cfg: cfg, instance_key: key,
                                         model_id: Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_id_for(entry),
                                         model_data: entry)
    end
    drafts.find { |draft| draft.model == model_id }
  end

  context 'when the catalog entry reports an explicit context_window' do
    let(:entries) do
      [{ 'id' => 'gpt-4o-prod', 'model_name' => 'gpt-4o',
         'context_window' => 128_000, 'max_output_tokens' => 16_384 }]
    end

    it 'flows context_window into the context evidence (not just metadata)' do
      draft = draft_for_model('gpt-4o-prod', entries)

      expect(draft.context_evidence.status).to eq(:known)
      expect(draft.context_evidence.value).to eq(128_000)
      expect(draft.context_evidence.source).to eq(:provider_catalog)
    end

    it 'flows max_output_tokens into the max-output evidence when declared' do
      draft = draft_for_model('gpt-4o-prod', entries)

      expect(draft.max_output_evidence.status).to eq(:known)
      expect(draft.max_output_evidence.value).to eq(16_384)
    end
  end

  context 'when the catalog entry reports max_input_tokens instead' do
    it 'derives a known context window from max_input_tokens' do
      draft = draft_for_model('custom-llama', [{ 'id' => 'custom-llama', 'max_input_tokens' => 32_768 }])

      expect(draft.context_evidence.status).to eq(:known)
      expect(draft.context_evidence.value).to eq(32_768)
    end
  end

  context 'when the catalog entry reports no context info' do
    it 'falls back to the instance-level context_window config' do
      draft = draft_for_model('private-mystery-model', [{ 'id' => 'private-mystery-model' }],
                              instance_cfg: { context_window: 64_000 })

      expect(draft.context_evidence.status).to eq(:known)
      expect(draft.context_evidence.value).to eq(64_000)
    end

    it 'leaves the context window unknown rather than guessing from a hardcoded table' do
      draft = draft_for_model('private-mystery-model', [{ 'id' => 'private-mystery-model' }])

      expect(draft.context_evidence.status).to eq(:unknown)
      expect(draft.context_evidence.value).to be_nil
    end
  end
end
