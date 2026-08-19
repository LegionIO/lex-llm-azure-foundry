# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable do
  it 'renders a folded leading system message in the OpenAI-dialect wire payload' do
    provider = Legion::Extensions::Llm::AzureFoundry::Provider.new(
      azure_foundry_endpoint: 'https://eastus.services.ai.azure.com',
      azure_foundry_api_key: 'ak-wire-spec',
      azure_foundry_surface: :model_inference,
      azure_foundry_deployments: [{ deployment: 'gpt-4o-deployment', model: 'gpt-4o' }]
    )
    captured_payload = nil
    connection = instance_double(Legion::Extensions::Llm::Connection)
    allow(connection).to receive(:post) do |_url, payload|
      captured_payload = payload
      Struct.new(:body).new({
                              'model' => 'gpt-4o',
                              'choices' => [{ 'message' => { 'role' => 'assistant', 'content' => 'ok' } }],
                              'usage' => { 'prompt_tokens' => 4, 'completion_tokens' => 1 }
                            })
    end
    provider.instance_variable_set(:@connection, connection)
    callable = described_class.new(
      instance_cfg: {}, logger: Logger.new(File::NULL), provider: provider
    )
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'authoritative system'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    callable.chat(messages: messages, model: 'gpt-4o')

    expect(captured_payload[:messages]).to eq(
      [
        { role: 'system', content: 'authoritative system' },
        { role: 'user', content: 'hello' }
      ]
    )
  end
end
