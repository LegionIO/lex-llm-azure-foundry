# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/azure_foundry/provider'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Provider do
  it 'exposes the 0.8.0 dispatch form: positional canonical messages, kwargs otherwise' do
    canonical_methods.each { |method_name| expect_dispatch_shape(method_name) }
  end

  # The 0.8.0 base funnel and the fleet callable contract take the canonical
  # message array positionally (kit B1: chat(messages, model:, ...)); the gem's
  # entries keep that one form and take everything else as keywords.
  def canonical_methods = %i[chat stream embed count_tokens]

  def expect_dispatch_shape(method_name)
    params = described_class.instance_method(method_name).parameters
    positional = params.select { |pair| pair.is_a?(Array) && %i[req opt].include?(pair.first) }
    expect(positional.map(&:last)).to eq(positional_messages(method_name)),
                                      "#{method_name} positional args: #{params.inspect}"
  end

  def positional_messages(method_name)
    %i[chat stream].include?(method_name) ? [:messages] : []
  end
end
