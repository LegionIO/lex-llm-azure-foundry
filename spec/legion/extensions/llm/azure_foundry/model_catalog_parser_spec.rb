# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser do
  describe '.model_info' do
    it 'uses the documented model_name and model_type response' do
      body = { model_name: 'served-model', model_type: 'chat-completion', model_provider_name: 'Publisher' }

      expect(described_class.model_info(body: body)).to eq(
        [body.merge(deployment_name: 'served-model', model_publisher: 'Publisher')]
      )
    end

    it 'does not treat a resource model catalog as served-model information' do
      expect { described_class.model_info(body: { data: [{ id: 'base-model' }] }) }
        .to raise_error(described_class::InvalidCatalog, /model-inference info/)
    end

    it 'rejects missing or malformed model identity and type' do
      [nil, [], {}, { model_name: '', model_type: 'embeddings' },
       { model_name: 'model', model_type: 'unknown' }].each do |body|
        expect { described_class.model_info(body: body) }.to raise_error(described_class::InvalidCatalog)
      end
    end
  end

  describe '.dedupe_by_model_id' do
    it 'collapses identical deployment records across page boundaries' do
      entry = { deployment_name: 'blue', model_name: 'base' }

      expect(described_class.dedupe_by_model_id(entries: [entry, entry.dup])).to eq([entry])
    end

    it 'preserves distinct deployment names for the same base model' do
      entries = [{ deployment_name: 'blue', model_name: 'base' }, { deployment_name: 'green', model_name: 'base' }]

      expect(described_class.dedupe_by_model_id(entries: entries)).to eq(entries)
    end

    it 'rejects conflicting records instead of choosing the first' do
      entries = [{ deployment_name: 'blue', model_name: 'base' }, { deployment_name: 'blue', model_name: 'other' }]

      expect { described_class.dedupe_by_model_id(entries: entries) }
        .to raise_error(described_class::InvalidCatalog, /conflicting/)
    end

    it 'does not guess deployment identity from other field names' do
      expect { described_class.dedupe_by_model_id(entries: [{ id: 'base', model_name: 'base' }]) }
        .to raise_error(described_class::InvalidCatalog, /deployment_name/)
    end
  end

  describe '.context_window_for' do
    it 'reads explicit positive context evidence' do
      expect(described_class.context_window_for(entry: { context_window: 128_000 })).to eq(128_000)
      expect(described_class.context_window_for(entry: { context_window: '128000' })).to eq(128_000)
    end

    it 'does not infer a total window from an input-only limit or absent evidence' do
      expect(described_class.context_window_for(entry: { max_input_tokens: 32_768 })).to be_nil
      expect(described_class.context_window_for(entry: {})).to be_nil
    end

    it 'rejects malformed numeric evidence' do
      ['128k', '128junk', -1, 0, 12.5].each do |value|
        expect(described_class.context_window_for(entry: { context_window: value })).to be_nil
      end
    end
  end
end
