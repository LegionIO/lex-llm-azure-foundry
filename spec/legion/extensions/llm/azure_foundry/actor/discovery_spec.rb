# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'legion/extensions/llm/azure_foundry/actors/discovery'
require 'legion/extensions/llm/azure_foundry/runners/discovery'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Actor::Discovery do
  # Exercise the real actor methods without starting a timer in the unit suite.
  subject(:actor) { described_class.allocate }

  let(:runner) { Legion::Extensions::Llm::AzureFoundry::Runners::Discovery }

  it 'inherits scheduling and dispatch from the actual host and shared discovery actor' do
    expect(described_class.superclass).to eq(Legion::Extensions::Llm::Discovery::Actor)
    expect(actor.method(:initialize).owner).to eq(Legion::Extensions::Actors::Every)
    expect(actor.method(:manual).owner).to eq(Legion::Extensions::Actors::Base)
    expect(actor.method(:runner_class).owner).to eq(Legion::Extensions::Llm::Discovery::Actor)
  end

  it 'dispatches the shared actor callback to the Azure discovery runner' do
    allow(runner).to receive(:refresh).and_return(:refreshed)

    expect(actor.manual).to eq(:refreshed)
    expect(runner).to have_received(:refresh).with(no_args)
  end

  it 'uses shared shutdown to remove the published instances' do
    allow(runner).to receive(:remove_all_instances).and_return(:removed)

    expect(actor.shutdown).to eq(:removed)
    expect(runner).to have_received(:remove_all_instances).with(no_args)
  end

  it 'loads the standalone provider without preloading or conditionally defining host actors' do
    script = <<~RUBY
      require 'legion/extensions/llm/azure_foundry'
      abort 'standalone provider loaded host actors' if defined?(Legion::Extensions::Actors)
      abort 'standalone provider loaded Azure actors' if
        Legion::Extensions::Llm::AzureFoundry.const_defined?(:Actor, false)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, '-e', script)

    expect(status.success?).to be(true), output
  end
end
