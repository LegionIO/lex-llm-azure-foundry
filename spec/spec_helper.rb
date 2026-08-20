# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/logging'
require 'legion/extensions/llm'

# Stub the LegionIO host-runtime pieces that are not available in the provider
# gem's spec environment before loading Azure Foundry (the production host
# always loads them; a missing runtime must fail loud at require time, not
# here).
require_relative 'support/actor_runtime_stubs'

Legion::Logging.setup(
  level: 'fatal',
  format: :text,
  async: false,
  log_file: File::NULL,
  log_stdout: false
)

require 'legion/extensions/llm/azure_foundry'

# Load the conformance kit from the lex-llm gem's spec/ directory (spec/ ships
# in the gem but is NOT on the load path). Per the kit's documented consumer
# pattern (conformance.rb, contract amendment 2026-08-20): load BY EXPLICIT
# NAME — never glob the kit dir, which also ships lex-llm's own self-test
# specs that LoadError outside this repo.
if Gem.loaded_specs['lex-llm']
  kit_path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path,
                       'spec/legion/extensions/llm/conformance')
  %w[conformance.rb canonical_type_examples.rb client_translator_examples.rb
     provider_translator_examples.rb provider_tool_rendering_examples.rb
     ssot_contract_examples.rb ssot_provider_examples.rb].each do |file|
    require File.join(kit_path, file)
  end
end
