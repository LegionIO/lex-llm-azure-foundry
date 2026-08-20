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

# Real callable boundary (09 §5.1): the production AzureFoundryCallable +
# production AzureFoundry::Provider traverse render_payload,
# parse_completion_response, and stream_response; only the HTTP connection is
# stubbed (sync bodies and SSE events at the wire edge).
RSpec.describe Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable do
  let(:instance_cfg) do
    { azure_foundry_endpoint: 'https://eastus.services.ai.azure.com',
      azure_foundry_api_key: 'ak-wire-spec', azure_foundry_surface: :model_inference }
  end
  let(:provider) do
    Legion::Extensions::Llm::AzureFoundry::Provider.new(
      azure_foundry_endpoint: 'https://eastus.services.ai.azure.com',
      azure_foundry_api_key: 'ak-wire-spec',
      azure_foundry_surface: :model_inference
    )
  end
  let(:callable) do
    described_class.new(instance_cfg: instance_cfg, logger: Logger.new(File::NULL), provider:)
  end

  before { stub_wire_edge }

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
    allow(provider.connection).to receive(:post) do |_url, _payload, &block|
      request = AzureFoundryWireRequestStub.new
      block&.call(request)
      on_data = request.options.on_data
      sse_events.each { |event| on_data.call(event, nil, nil) } if on_data
      Struct.new(:body).new(sync_body)
    end
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
