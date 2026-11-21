# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Provider do
  surfaces = {
    model_inference: { url: 'https://resource.example/models/chat/completions?api-version=2024-05-01-preview',
                       key: :max_tokens, excluded: :max_completion_tokens },
    openai_v1: { url: 'https://resource.example/openai/v1/chat/completions',
                 key: :max_completion_tokens, excluded: :max_tokens }
  }
  budgets = [128_000, nil]
  operations = %i[chat stream_chat]

  surfaces.each do |surface, wire|
    context "with #{surface} protocol" do
      let(:provider) do
        described_class.new(azure_foundry_endpoint: 'https://resource.example', azure_foundry_api_key: 'test-key',
                            azure_foundry_surface: surface, azure_foundry_api_version: '2024-05-01-preview')
      end
      let(:messages) { [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Hello')] }

      operations.each do |operation|
        budgets.each do |budget|
          it "preserves budget #{budget.inspect} once on the #{operation} wire without mutating canonical params" do
            params = Legion::Extensions::Llm::Canonical::Params.build(max_tokens: budget,
                                                                      metadata: { owner: 'request' })
            original = Legion::JSON.dump(params.to_h)
            payloads = []
            chunks = []
            stubs = Faraday::Adapter::Test::Stubs.new do |stub|
              stub.post(wire.fetch(:url)) do |env|
                payloads << Legion::JSON.load(env.body)
                expect(env.request_headers['api-key']).to eq('test-key')
                operation == :stream_chat ? stream_response(env: env) : sync_response
              end
            end
            provider.connection.connection.builder.adapter(:test, stubs)

            response = if operation == :stream_chat
                         provider.stream_chat(messages, model: 'selected-deployment', params: params) do |chunk|
                           chunks << chunk
                         end
                       else
                         provider.chat(messages, model: 'selected-deployment', params: params)
                       end

            expect(payloads.size).to eq(1)
            payload = payloads.first
            expect(payload).to include(model: 'selected-deployment', stream: operation == :stream_chat)
            expected = budget.nil? ? {} : { wire.fetch(:key) => budget }
            expect(payload.slice(:max_tokens, :max_completion_tokens)).to eq(expected)
            expect(payload).not_to have_key(wire.fetch(:excluded))
            expect(Legion::JSON.dump(params.to_h)).to eq(original)
            expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
            expect(response.text).to eq('ok')
            expect(chunks.count { |chunk| chunk.type == :done }).to eq(1) if operation == :stream_chat
            stubs.verify_stubbed_calls
          end
        end
      end
    end
  end

  context 'with a supported GPT-5 mini reasoning request' do
    let(:provider) do
      described_class.new(azure_foundry_endpoint: 'https://resource.example', azure_foundry_api_key: 'test-key',
                          azure_foundry_surface: :openai_v1)
    end
    let(:messages) { [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'What is 17 * 23?')] }

    operations.each do |operation|
      it "preserves high effort, the output allowance, and reported thinking usage through #{operation}" do
        params = Legion::Extensions::Llm::Canonical::Params.build(max_tokens: 128_000)
        thinking = Legion::Extensions::Llm::Canonical::Thinking::Config.build(enabled: true, budget: 16_384)
        original = Legion::JSON.dump({ params: params.to_h, thinking: thinking.to_h })
        usage = { prompt_tokens: 12, completion_tokens: 9, completion_tokens_details: { reasoning_tokens: 7 } }
        chunks = []
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.post('https://resource.example/openai/v1/chat/completions') do |env|
            payload = Legion::JSON.load(env.body)
            expect(payload).to include(model: 'reasoning-slot', reasoning_effort: 'high',
                                       max_completion_tokens: 128_000)
            expect(payload).not_to have_key(:max_tokens)
            expect(payload).not_to have_key(:temperature)
            operation == :stream_chat ? stream_response(env: env, usage: usage) : sync_response(usage: usage)
          end
        end
        provider.connection.connection.builder.adapter(:test, stubs)

        response = if operation == :stream_chat
                     provider.stream_chat(messages, model: 'reasoning-slot', params: params,
                                                    thinking: thinking) do |chunk|
                       chunks << chunk
                     end
                   else
                     provider.chat(messages, model: 'reasoning-slot', params: params, thinking: thinking)
                   end

        expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
        expect(response.usage).to have_attributes(input_tokens: 12, output_tokens: 9, thinking_tokens: 7)
        expect(Legion::JSON.dump({ params: params.to_h, thinking: thinking.to_h })).to eq(original)
        if operation == :stream_chat
          expect(chunks.count { |chunk| chunk.type == :done }).to eq(1)
          expect(chunks.last.usage).to have_attributes(output_tokens: 9, thinking_tokens: 7)
        end
        stubs.verify_stubbed_calls
      end
    end
  end

  def sync_response(usage: { prompt_tokens: 2, completion_tokens: 1 })
    body = { model: 'selected-deployment',
             choices: [{ message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }],
             usage: usage }
    [200, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]
  end

  def stream_response(env:, usage: { prompt_tokens: 2, completion_tokens: 1 })
    env.status = 200
    env.response_headers = { 'content-type' => 'text/event-stream' }
    frames = [
      { choices: [{ index: 0, delta: { content: 'ok' }, finish_reason: 'stop' }] },
      { choices: [], usage: usage }
    ]
    frames.each do |frame|
      data = "data: #{Legion::JSON.dump(frame)}\n\n"
      env.request.on_data.call(data, data.bytesize, env)
    end
    env.request.on_data.call("data: [DONE]\n\n", 14, env)
    [200, env.response_headers, '']
  end
end
