# frozen_string_literal: true

require 'spec_helper'

# The 09 boundary kit (B1/B2) — the single oracle for the dispatch boundary,
# loaded by spec_helper per the kit's documented explicit-file consumer
# pattern (09 §5, contract amendment 2026-08-20).

# Faraday request stand-in for the stubbed connection: the production
# stream path sets req.options.on_data (Faraday 2) and merges headers.
class AzureFoundryWireRequestStub
  attr_accessor :headers

  def initialize
    @headers = {}
    @options = Faraday::RequestOptions.new
  end

  attr_reader :options
end

# Real provider boundary (09 §5.1): AzureFoundry::Provider traverses render_payload,
# parse_completion_response, and stream_response; only the HTTP connection is
# stubbed (sync bodies and SSE events at the wire edge).
RSpec.describe Legion::Extensions::Llm::AzureFoundry::Provider do
  let(:instance_cfg) do
    { azure_foundry_endpoint: 'https://eastus.services.ai.azure.com',
      azure_foundry_api_key: 'ak-wire-spec', azure_foundry_surface: :model_inference,
      azure_foundry_api_version: '2024-05-01-preview' }
  end
  let(:provider) do
    described_class.new(instance_cfg)
  end
  let(:callable) { provider }
  let(:captured) { {} }

  before { stub_wire_edge }

  %i[chat stream_chat].each do |operation|
    it "preserves named controls through the shared #{operation} funnel" do
      thinking = Legion::Extensions::Llm::Canonical::Thinking::Config.build(effort: 'high')
      schema = { name: 'answer', schema: { type: 'object', properties: { answer: { type: 'string' } } } }
      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')]
      params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2, max_tokens: 256)

      callable.public_send(operation, messages, model: 'deployment', thinking: thinking, schema: schema,
                                                headers: { 'X-Request-Probe' => 'kept' }, params: params) do |chunk|
        captured[:chunk] = chunk
      end

      expect(captured[:payload]).to include(
        reasoning_effort: 'high', temperature: 0.2, max_tokens: 256,
        response_format: { type: 'json_schema', json_schema: schema }
      )
      expect(captured[:headers]).to include('X-Request-Probe' => 'kept')
    end
  end

  it 'does not interpret flat sampling kwargs as an alternate parameter contract' do
    messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')]

    expect { callable.chat(messages, model: 'deployment', temperature: 0.2) }
      .to raise_error(ArgumentError, /temperature/)
  end

  it 'inherits completion and embedding execution from the shared provider' do
    %i[chat stream_chat complete embed health discover_offerings].each do |operation|
      expect(provider.method(operation).owner).to eq(Legion::Extensions::Llm::Provider)
    end
  end

  it 'renders a folded leading system message in the OpenAI-dialect wire payload' do
    captured_payload = nil
    allow(provider.connection).to receive(:post) do |_url, payload|
      captured_payload = payload
      Struct.new(:body).new({
                              'model' => 'gpt-4o',
                              'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => 'ok' } }],
                              'usage' => { 'prompt_tokens' => 4, 'completion_tokens' => 1 }
                            })
    end

    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'authoritative system'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    callable.chat(messages, model: 'gpt-4o')

    expect(captured_payload[:messages]).to eq(
      [
        { role: 'system', content: 'authoritative system' },
        { role: 'user', content: 'hello' }
      ]
    )
  end

  it_behaves_like 'B1 — central canonical enforcement (08 F2)'
  it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'

  # The wire edge: the production stream path installs req.options.on_data
  # and feeds SSE through it; the sync path only merges headers. The stub
  # distinguishes the two by whether on_data was installed.
  def stub_wire_edge
    allow(provider.connection).to receive(:post) do |_url, payload, &block|
      captured[:payload] = payload
      request = AzureFoundryWireRequestStub.new
      block&.call(request)
      captured[:headers] = request.headers
      emit_stub_stream(request)
      Struct.new(:body).new(sync_body)
    end
  end

  def emit_stub_stream(request)
    on_data = request.options.on_data
    sse_events.each { |event| on_data.call(event, nil, nil) } if on_data
  end

  def sync_body
    {
      'model' => 'gpt-4o',
      'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => 'ok' }, 'finish_reason' => 'stop' }],
      'usage' => { 'prompt_tokens' => 4, 'completion_tokens' => 1 }
    }
  end

  def sse_events
    [
      "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n",
      'data: {"choices":[{"delta":{"content":"lo"}}],' \
      "\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}\n\n",
      "data: [DONE]\n\n"
    ]
  end
end
