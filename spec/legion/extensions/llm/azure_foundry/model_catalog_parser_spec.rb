# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser do
  subject(:parser) { described_class }

  describe '.model_entries' do
    it 'accepts a bare array body' do
      body = [{ 'id' => 'a' }, { 'id' => 'b' }]
      expect(parser.model_entries(body: body)).to eq([{ 'id' => 'a' }, { 'id' => 'b' }])
    end

    %w[data models value models_list deployments].each do |list_key|
      it "accepts a #{list_key} list envelope (symbol and string keys)" do
        expect(parser.model_entries(body: { list_key => [{ 'id' => 'a' }] })).to eq([{ 'id' => 'a' }])
        expect(parser.model_entries(body: { list_key.to_sym => [{ 'id' => 'a' }] })).to eq([{ 'id' => 'a' }])
      end
    end

    it 'accepts a single model object (no list key) as a one-element catalog' do
      body = { 'id' => 'gpt-4o-deployment', 'model_name' => 'gpt-4o' }
      expect(parser.model_entries(body: body)).to eq([body])
    end

    it 'rejects malformed entries instead of publishing a partial or empty catalog' do
      expect { parser.model_entries(body: { 'data' => ['not-a-hash', { 'id' => 'a' }] }) }
        .to raise_error(described_class::InvalidCatalog, /array of model records/)
    end

    it 'distinguishes an empty catalog from a malformed list field' do
      expect(parser.model_entries(body: { data: [] })).to eq([])
      expect { parser.model_entries(body: { data: nil }) }
        .to raise_error(described_class::InvalidCatalog, /array of model records/)
    end

    # Regression: the Azure-served OpenAI catalog reports some model ids
    # more than once (duplicates differ only in created_at); a repeat of the
    # resolved id would surface as a duplicate provider_native_key and the
    # registry build_records raises ValidationError on it.
    it 'collapses repeated model ids to the first occurrence' do
      first  = { 'id' => 'gpt-4o', 'created_at' => 1 }
      second = { 'id' => 'gpt-4o', 'created_at' => 2 }
      expect(parser.model_entries(body: { 'data' => [first, { 'id' => 'other' }, second] }))
        .to eq([first, { 'id' => 'other' }])
    end

    it 'does not collapse distinct entries lacking a resolvable id' do
      entries = [{ 'model_name' => 'base' }, { 'model_name' => 'base' }]
      expect(parser.model_entries(body: entries)).to eq(entries)
    end

    it 'raises on an unrecognized envelope rather than returning an empty catalog' do
      expect { parser.model_entries(body: { 'unexpected' => 1 }) }
        .to raise_error(described_class::InvalidCatalog, /unrecognized Azure Foundry catalog envelope/)
    end

    it 'raises on scalar bodies' do
      expect do
        parser.model_entries(body: 'not json')
      end.to raise_error(described_class::InvalidCatalog, /must be a Hash or Array/)
    end
  end

  describe '.model_id_for' do
    # Only the deployment-unique keys are identity keys — the base-model keys
    # (model_name / model) are excluded so two deployments of one base model
    # never collapse onto one provider_native_key.
    %w[id deployment_name name].each do |key|
      it "resolves the identity from the deployment-unique key #{key}" do
        expect(parser.model_id_for(key => 'deploy-1')).to eq('deploy-1')
      end
    end

    it 'prefers id over the other identity keys' do
      expect(parser.model_id_for('id' => 'deploy-1', 'name' => 'base-1')).to eq('deploy-1')
    end

    it 'prefers the unique deployment_name over the ambiguous name' do
      expect(parser.model_id_for('deployment_name' => 'gpt-4o-blue', 'name' => 'gpt-4o')).to eq('gpt-4o-blue')
    end

    # Regression: the shared base-model keys must NOT resolve as identity —
    # two distinct deployments of one base model share them, and using them
    # collapses both drafts onto one provider_native_key (registry
    # build_records raises ValidationError: duplicate provider_native_key).
    %w[model_name model].each do |base_key|
      it "does NOT resolve the identity from the shared base-model key #{base_key}" do
        expect(parser.model_id_for(base_key => 'gpt-4o')).to be_nil
      end
    end

    it 'resolves the deployment id even when a shared base model is also present' do
      expect(parser.model_id_for('deployment_name' => 'gpt-4o-blue', 'model' => 'gpt-4o')).to eq('gpt-4o-blue')
    end

    it 'returns nil when no identity key is present' do
      expect(parser.model_id_for({ 'other' => 'x' })).to be_nil
    end
  end

  describe '.base_model_name_for' do
    it 'reads the base model name when distinct from the routable id' do
      expect(parser.base_model_name_for('id' => 'deploy-1', 'model_name' => 'gpt-4o')).to eq('gpt-4o')
    end

    it 'returns nil when the catalog reports no base name' do
      expect(parser.base_model_name_for('id' => 'deploy-1')).to be_nil
    end
  end

  describe '.context_window_for' do
    { 'context_window' => 128_000, 'max_input_tokens' => 32_768, 'context_length' => 8_192 }.each do |key, value|
      it "reads #{key}" do
        expect(parser.context_window_for(key => value)).to eq(value)
      end
    end

    it 'coerces numeric strings' do
      expect(parser.context_window_for('context_window' => '128000')).to eq(128_000)
    end

    it 'returns nil when absent' do
      expect(parser.context_window_for('id' => 'a')).to be_nil
    end

    it 'rejects malformed or non-positive numeric evidence' do
      ['128k', '128junk', -1, 0, 12.5].each do |value|
        expect(parser.context_window_for(context_window: value)).to be_nil
      end
    end
  end

  describe '.model_family_for' do
    { 'gpt-4o' => :openai, 'text-embedding-3-small' => :openai, 'mistral-large-latest' => :mistral,
      'Llama-4-Maverick' => :meta, 'grok-4-fast' => :xai, 'claude-opus-4-6' => :anthropic, 'phi-4' => :microsoft }
      .each do |name, family|
        it "infers #{family} from #{name}" do
          expect(parser.model_family_for(name)).to eq(family)
        end
      end

    it 'returns nil for an unrecognized name' do
      expect(parser.model_family_for('mystery-model-v1')).to be_nil
    end
  end
end
