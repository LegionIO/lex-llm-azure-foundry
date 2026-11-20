# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/azure_foundry/runners/discovery'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Runners::Discovery do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:resource_url) { 'https://resource.example/openai/v1/models' }
  let(:catalog) do
    [
      { id: 'base-chat', capabilities: { chat_completion: true, embeddings: false, streaming: true,
                                         function_calling: true } },
      { id: 'base-vector', capabilities: { chat_completion: false, embeddings: true } },
      { id: 'undeclared-base', capabilities: { chat_completion: true } }
    ]
  end
  let(:bindings) { [{ name: 'chat-slot', model: 'base-chat' }, { name: 'vector-slot', model: 'base-vector' }] }
  let(:instance) do
    {
      endpoint: 'https://resource.example', credentials: { api_key: 'resource-key' },
      provider: { surface: :openai_v1, discovery_source: :declared, deployments: bindings,
                  project_endpoint: 'https://unused.example/api/projects/unused' }
    }
  end

  def tree = Legion::Settings[:extensions][:llm][:azure_foundry]
  def config = Legion::Extensions::Llm::AzureFoundry.discover_instances.fetch(:primary)
  def response(status: 200, **body) = [status, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]

  before do
    registry.reset!
    described_class.reset_state!
    defaults = Legion::Extensions::Llm::AzureFoundry.default_settings
    Legion::Settings[:extensions][:llm] = { azure_foundry: defaults.merge(instances: { primary: instance }) }
    allow(described_class).to receive(:build_connection).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).tap { |connection| connection.adapter(:test, stubs) }
    end
  end

  after do
    described_class.remove_all_instances
    registry.reset!
    described_class.reset_state!
  end

  it 'publishes only declared identities with live catalog evidence through the shared lifecycle' do
    stubs.get(resource_url) do |env|
      expect(env.request_headers['api-key']).to eq('resource-key')
      expect(env.request_headers).not_to have_key('Authorization')
      response(data: catalog)
    end

    described_class.refresh

    expect(described_class.method(:refresh).owner).to eq(Legion::Extensions::Llm::Discovery::Pipeline)
    lanes = registry.snapshot.each_lane.to_a
    expect(lanes.map(&:model)).to contain_exactly('chat-slot', 'vector-slot')
    expect(lanes.map { |lane| lane.metadata[:declared] }).to all(be(true))
    expect(lanes.to_h { |lane| [lane.model, lane.metadata[:canonical_model_alias]] })
      .to eq('chat-slot' => 'base-chat', 'vector-slot' => 'base-vector')
    drafts = described_class.states.fetch('primary')[:offerings]
    expect(drafts.map(&:publication_source)).to all(eq(:provider_static_catalog))
    expect(drafts.find { |draft| draft.model == 'chat-slot' }.operation_evidence[:chat].status).to eq(:supported)
    expect(drafts.find { |draft| draft.model == 'vector-slot' }.operation_evidence[:chat].status).to eq(:unsupported)
    expect(drafts.map { |draft| draft.context_evidence.status }).to all(eq(:unknown))
    expect(drafts.map { |draft| draft.max_output_evidence.status }).to all(eq(:unknown))
    provider = described_class.states.fetch('primary')[:callable]
    expect(provider).to be_an_instance_of(Legion::Extensions::Llm::AzureFoundry::Provider)
    expect(provider.discover_offerings.map(&:lane_id)).to match_array(lanes.map(&:lane_id))
    stubs.verify_stubbed_calls
  end

  it 'dispatches canonical messages and tools to the declared deployment name using the real provider' do
    stubs.get(resource_url) { response(data: catalog) }
    described_class.refresh
    lane = registry.snapshot.each_lane.find { |entry| entry.model == 'chat-slot' }
    lease = registry.acquire(callable_handle: lane.callable_handle)
    provider = lease.callable
    provider.connection.connection.adapter(:test, stubs)
    stubs.post('https://resource.example/openai/v1/chat/completions') do |env|
      payload = Legion::JSON.load(env.body)
      expect(env.request_headers['api-key']).to eq('resource-key')
      expect(payload).to include(model: 'chat-slot', max_tokens: 512, reasoning_effort: 'high')
      expect(payload[:messages]).to eq([{ role: 'system', content: 'Be precise' },
                                        { role: 'user', content: 'Look up status' }])
      expect(payload[:tools].first[:function][:name]).to eq('lookup')
      response(model: 'chat-slot',
               choices: [{ message: { role: 'assistant', content: 'ready' }, finish_reason: 'stop' }])
    end
    request = Legion::Extensions::Llm::Canonical::Request.build(
      messages: [{ role: :system, content: 'Be precise' }, { role: :user, content: 'Look up status' }],
      tools: { lookup: { name: 'lookup', parameters: { type: 'object', properties: {} } } },
      params: { max_tokens: 512 }, thinking: { enabled: true, effort: 'high' }
    )

    result = provider.chat(request.messages, model: lane.model, tools: request.tools,
                                             params: request.params, thinking: request.thinking)

    expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(result.text).to eq('ready')
    stubs.verify_stubbed_calls
  ensure
    lease&.release
  end

  it 'keeps identical deployment names distinct across configured instances' do
    tree[:instances][:secondary] = {
      endpoint: 'https://secondary.example', credentials: { api_key: 'secondary-key' },
      provider: { surface: :openai_v1, discovery_source: :declared,
                  deployments: [{ name: 'chat-slot', model: 'base-chat' }] }
    }
    stubs.get(resource_url) { response(data: catalog) }
    stubs.get('https://secondary.example/openai/v1/models') do |env|
      expect(env.request_headers['api-key']).to eq('secondary-key')
      response(data: catalog)
    end

    described_class.refresh

    lanes = registry.snapshot.each_lane.select { |lane| lane.model == 'chat-slot' }
    expect(lanes.map(&:instance_id)).to contain_exactly('primary', 'secondary')
    expect(lanes.map(&:callable_handle).uniq.size).to eq(2)
  end

  it 'uses the declared embedding name through the inherited embedding operation' do
    stubs.get(resource_url) { response(data: catalog) }
    described_class.refresh
    lane = registry.snapshot.each_lane.find { |entry| entry.model == 'vector-slot' }
    lease = registry.acquire(callable_handle: lane.callable_handle)
    provider = lease.callable
    provider.connection.connection.adapter(:test, stubs)
    stubs.post('https://resource.example/openai/v1/embeddings') do |env|
      expect(env.request_headers['api-key']).to eq('resource-key')
      expect(Legion::JSON.load(env.body)).to eq(model: 'vector-slot', input: 'hello')
      response(data: [{ embedding: [0.25, 0.5] }], usage: { prompt_tokens: 1, total_tokens: 1 })
    end

    result = provider.embed(text: 'hello', model: lane.model)

    expect(result).to include(model: 'vector-slot', embedding: [0.25, 0.5])
    expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    stubs.verify_stubbed_calls
  ensure
    lease&.release
  end

  it 'replaces changed bindings and removes withdrawn ones at the normal refresh boundary' do
    stubs.get(resource_url) { response(data: catalog) }
    described_class.refresh
    provider = described_class.states.fetch('primary')[:callable]
    expect(registry.snapshot.each_lane.map(&:model)).to contain_exactly('chat-slot', 'vector-slot')

    tree[:instances][:primary][:provider][:deployments] = [{ name: 'renamed-slot', model: 'base-chat' }]
    described_class.refresh

    expect(registry.snapshot.each_lane.map(&:model)).to eq(['renamed-slot'])
    expect(described_class.states.fetch('primary')[:callable]).to equal(provider)
    tree[:instances][:primary][:provider][:deployments] = []
    described_class.refresh
    expect(registry.snapshot.each_lane.to_a).to be_empty
  end

  it 'retires a removed instance through the shared lease lifecycle' do
    stubs.get(resource_url) { response(data: catalog) }
    described_class.refresh
    lane = registry.snapshot.each_lane.first
    lease = registry.acquire(callable_handle: lane.callable_handle)
    provider = lease.callable

    tree[:instances] = {}
    described_class.refresh

    expect(registry.snapshot.each_lane.to_a).to be_empty
    expect(provider.connection).not_to be_nil
    lease.release
    lease = nil
    expect(provider.connection).to be_nil
  ensure
    lease&.release
  end

  it 'withdraws all declarations during a catalog outage while retaining the normal health probe' do
    unavailable = false
    requests = 0
    stubs.get(resource_url) do
      requests += 1
      raise Faraday::ConnectionFailed, 'catalog unavailable' if unavailable

      response(data: catalog)
    end
    described_class.refresh
    expect(registry.snapshot.each_lane.map(&:model)).to contain_exactly('chat-slot', 'vector-slot')
    expect(requests).to eq(2) # Initial catalog observation and startup readiness.

    tree[:instances][:primary][:provider][:deployments] = []
    unavailable = true
    described_class.refresh

    expect(registry.snapshot.each_lane.to_a).to be_empty
    expect(described_class.states.fetch('primary')[:sequence]).to eq(1)
    expect(requests).to eq(3) # Withdrawal needs no catalog GET; cadence readiness still runs.
  end

  it 'runs startup readiness for empty declarations without fetching model facts' do
    tree[:instances][:primary][:provider][:deployments] = []
    requests = 0
    stubs.get(resource_url) do
      requests += 1
      response(data: [])
    end

    described_class.refresh

    key = described_class.states.fetch('primary')[:instance_key]
    expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    expect(registry.snapshot.each_lane.to_a).to be_empty
    expect(requests).to eq(1)
  end

  it 'does not activate empty declarations when startup readiness fails' do
    tree[:instances][:primary][:provider][:deployments] = []
    requests = 0
    stubs.get(resource_url) do
      requests += 1
      raise Faraday::ConnectionFailed, 'resource unavailable'
    end

    described_class.refresh

    key = described_class.states.fetch('primary')[:instance_key]
    expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    expect(registry.snapshot.each_lane.to_a).to be_empty
    expect(requests).to eq(1)
  end

  it 'retains the last complete snapshot when any declared base model is missing' do
    stubs.get(resource_url) { response(data: catalog) }
    described_class.refresh
    previous = registry.snapshot.each_lane.map(&:lane_id)
    expect(previous).not_to be_empty
    tree[:instances][:primary][:provider][:deployments] << { name: 'missing-slot', model: 'missing-base' }

    described_class.refresh

    expect(registry.snapshot.each_lane.map(&:lane_id)).to eq(previous)
    expect(described_class.states.fetch('primary')[:sequence]).to eq(0)
  end

  it 'rejects conflicting base catalog records instead of picking one' do
    stubs.get(resource_url) do
      response(data: catalog + [catalog.first.merge(capabilities: { chat_completion: false })])
    end

    expect { described_class.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /conflicting/)
    expect(registry.snapshot.each_lane.to_a).to be_empty
  end

  it 'publishes selected bindings when an unselected base model has conflicting catalog records' do
    unrelated = catalog.last.merge(capabilities: { chat_completion: false, embeddings: true })
    stubs.get(resource_url) { response(data: catalog + [unrelated]) }

    described_class.refresh

    expect(registry.snapshot.each_lane.map(&:model)).to contain_exactly('chat-slot', 'vector-slot')
    expect(described_class.states.fetch('primary')[:offerings].map(&:provider_native_key))
      .to contain_exactly('chat-slot', 'vector-slot')
    stubs.verify_stubbed_calls
  end

  [{}, { id: 42 }].each do |invalid|
    it "still rejects malformed unselected catalog identities #{invalid.inspect}" do
      stubs.get(resource_url) { response(data: catalog + [invalid]) }

      expect { described_class.fetch_raw_models(instance_cfg: config) }
        .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, /invalid model id/)
      expect(registry.snapshot.each_lane.to_a).to be_empty
    end
  end

  it 'retains the last complete snapshot when catalog authentication fails' do
    rejected = false
    stubs.get(resource_url) { rejected ? response(status: 401, error: 'Unauthorized') : response(data: catalog) }
    described_class.refresh
    previous = registry.snapshot.each_lane.map(&:lane_id)
    expect(previous).not_to be_empty

    rejected = true
    described_class.refresh

    expect(registry.snapshot.each_lane.map(&:lane_id)).to eq(previous)
  end

  it 'does not turn unknown catalog facts into supported capabilities or fabricated limits' do
    stubs.get(resource_url) { response(data: [{ id: 'base-chat', capabilities: { chat_completion: true } }]) }
    tree[:instances][:primary][:provider][:deployments] = [bindings.first]

    described_class.refresh

    draft = described_class.states.fetch('primary')[:offerings].first
    expect(draft.capability_evidence[:tools].status).to eq(:unknown)
    expect(draft.capability_evidence[:vision].status).to eq(:unknown)
    expect(draft.context_evidence.status).to eq(:unknown)
    expect(draft.max_output_evidence.status).to eq(:unknown)
  end

  [nil, {}, [{ name: 'missing-model' }], [{ name: 'bad', model: 'base-chat', context_window: 64_000 }],
   [{ name: 'bad', model: 'base-chat', capabilities: { tools: true } }],
   [{ name: 'same', model: 'base-chat' }, { name: 'same', model: 'base-chat' }]].each do |invalid|
    it "rejects invalid deployment bindings #{invalid.inspect}" do
      tree[:instances][:primary][:provider][:deployments] = invalid

      expect { described_class.fetch_raw_models(instance_cfg: config) }
        .to raise_error(Legion::Extensions::Llm::ConfigurationError, /deployments|binding/)
    end
  end

  it 'rejects an unrecognized discovery source without trying another source' do
    tree[:instances][:primary][:provider][:discovery_source] = 'unknown'

    expect { described_class.fetch_raw_models(instance_cfg: config) }
      .to raise_error(Legion::Extensions::Llm::ConfigurationError, /discovery_source/)
  end

  context 'with an exact documented model version and deployment type' do
    let(:bindings) do
      [{ name: 'mini-slot', model: 'gpt-4o-mini', model_version: '2024-07-18', deployment_type: 'GlobalStandard' }]
    end
    let(:catalog) { [{ id: 'gpt-4o-mini', capabilities: { chat_completion: true, streaming: true } }] }

    before { stubs.get(resource_url) { response(data: catalog) } }

    it 'uses one versioned vendor metadata owner for documented facts absent from the live catalog' do
      described_class.refresh

      draft = described_class.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.to_h).to include(status: :known, value: 128_000, source: :model_metadata)
      expect(draft.max_output_evidence.to_h).to include(status: :known, value: 16_384, source: :model_metadata)
      expect(draft.capability_evidence[:vision].to_h).to include(status: :supported, source: :model_metadata)
      expect(draft.capability_evidence[:tools].to_h).to include(status: :supported, source: :model_metadata)
      expect(draft.model_revision_evidence.status).to eq(:unknown)
      expect(draft.metadata).to include(declared: true, declared_model_version: '2024-07-18',
                                        declared_deployment_type: 'GlobalStandard')
    end

    it 'uses the documented GlobalStandard GPT-4.1 tuple without applying it to other deployment types' do
      tree[:instances][:primary][:provider][:deployments] = [
        { name: 'large-slot', model: 'gpt-4.1', model_version: '2025-04-14', deployment_type: 'GlobalStandard' }
      ]
      catalog.replace([{ id: 'gpt-4.1', capabilities: { chat_completion: true } }])

      described_class.refresh

      draft = described_class.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.to_h).to include(status: :known, value: 1_047_576, source: :model_metadata)
      expect(draft.max_output_evidence.to_h).to include(status: :known, value: 32_768, source: :model_metadata)
      expect(draft.operation_evidence[:stream_chat].to_h).to include(status: :supported, source: :model_metadata)
      expect(draft.capability_evidence[:tools].to_h).to include(status: :supported, source: :model_metadata)
    end

    it 'preserves explicit catalog negatives and limits over vendor metadata' do
      catalog.first[:capabilities].merge!(vision: false, function_calling: false, chat_completion: false,
                                          streaming: false)
      catalog.first[:context_window] = 64_000
      catalog.first[:max_output_tokens] = 4096

      described_class.refresh

      draft = described_class.states.fetch('primary')[:offerings].first
      expect(draft.context_evidence.to_h).to include(value: 64_000, source: :provider_catalog)
      expect(draft.max_output_evidence.to_h).to include(value: 4096, source: :provider_catalog)
      expect(draft.capability_evidence[:vision].to_h).to include(status: :unsupported, source: :provider_catalog)
      expect(draft.capability_evidence[:tools].to_h).to include(status: :unsupported, source: :provider_catalog)
      expect(draft.operation_evidence[:chat].to_h).to include(status: :unsupported, source: :provider_catalog)
      expect(draft.operation_evidence[:stream_chat].to_h).to include(status: :unsupported, source: :provider_catalog)
    end

    { model_version: 'unknown-version', deployment_type: 'UnknownSku' }.each do |key, value|
      it "does not infer vendor facts for an unknown #{key}" do
        tree[:instances][:primary][:provider][:deployments].first[key] = value

        described_class.refresh

        draft = described_class.states.fetch('primary')[:offerings].first
        expect(draft.context_evidence.status).to eq(:unknown)
        expect(draft.max_output_evidence.status).to eq(:unknown)
        expect(draft.capability_evidence[:vision].status).to eq(:unknown)
      end
    end
  end
end
