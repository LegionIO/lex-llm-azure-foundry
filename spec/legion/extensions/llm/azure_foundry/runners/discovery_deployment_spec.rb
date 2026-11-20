# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/azure_foundry/runners/discovery'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Runners::Discovery do
  let(:runner) { described_class }
  let(:key) do
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry, instance_id: 'primary'
    )
  end
  let(:config) do
    { azure_foundry_endpoint: 'https://resource.example/models', azure_foundry_surface: :model_inference,
      azure_foundry_api_version: '2024-05-01-preview' }
  end

  before do
    Legion::Settings[:extensions][:llm] = { azure_foundry: Legion::Extensions::Llm::AzureFoundry.default_settings }
  end

  def draft(entry, instance_cfg: config)
    runner.build_offering_draft(instance_cfg: instance_cfg, instance_key: key,
                                model_id: runner.model_id_from(entry), model_data: entry)
  end

  it 'uses the same endpoint normalization for discovery and inference' do
    provider = Legion::Extensions::Llm::AzureFoundry::Provider.new(config)

    expect(runner.catalog_base_url(instance_cfg: config)).to eq(provider.api_base)
    expect(runner.catalog_path(instance_cfg: config)).to eq(provider.models_url)
  end

  it 'publishes the documented single-model info response without inventing an id' do
    body = { model_name: 'semantic-service', model_type: 'embeddings', model_provider_name: 'Example' }
    response = Struct.new(:status, :body).new(200, Legion::JSON.dump(body))
    connection = instance_double(Faraday::Connection, get: response)
    allow(runner).to receive(:build_connection).and_return(connection)

    offerings = runner.build_offerings(instance_cfg: config, instance_key: key)

    expect(offerings.map(&:model)).to eq(['semantic-service'])
    expect(offerings.first.operation_evidence[:embed].status).to eq(:supported)
    expect(offerings.first.operation_evidence[:chat].status).to eq(:unsupported)
  end

  it 'does not publish the OpenAI base-model catalog as deployed models' do
    body = { data: [{ id: 'Cohere-Embed-V5-Fast', object: 'model', capabilities: { embeddings: true } }] }
    response = Struct.new(:status, :body).new(200, Legion::JSON.dump(body))
    connection = instance_double(Faraday::Connection, get: response)
    allow(runner).to receive(:build_connection).and_return(connection)
    cfg = config.merge(azure_foundry_surface: :openai_v1)

    expect { runner.build_offerings(instance_cfg: cfg, instance_key: key) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /deploy/i)
  end

  it 'honors explicit negative operation evidence even when the name looks like an embedding model' do
    offering = draft({ id: 'embed-in-name', capabilities: { embeddings: false, chat_completion: true } })

    expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    expect(offering.operation_evidence[:chat].status).to eq(:supported)
    expect(offering.operation_evidence[:chat].source).to eq(:provider_catalog)
  end

  it 'leaves absent operation and tool evidence unknown instead of guessing from names' do
    offering = draft({ id: 'gpt-chat-embed-vision' })

    expect(offering.operation_evidence.values_at(:chat, :embed).map(&:status)).to eq(%i[unknown unknown])
    expect(offering.capability_evidence.values_at(:tools, :vision, :thinking).map(&:status))
      .to eq(%i[unknown unknown unknown])
  end

  it 'does not relabel operator context limits as authoritative provider facts' do
    offering = draft({ id: 'deployment' }, instance_cfg: config.merge(context_window: 65_536))

    expect(offering.context_evidence.status).to eq(:unknown)
    expect(offering.context_evidence.value).to be_nil
  end

  it 'preserves deployment identity when the service also supplies a base model id' do
    parser = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser

    expect(parser.model_id_for({ id: 'base-model', deployment_name: 'production-chat' })).to eq('production-chat')
  end
end
