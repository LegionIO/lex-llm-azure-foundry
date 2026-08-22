# frozen_string_literal: true

require 'bundler/setup'
require 'logger'
require 'stringio'

require 'legion/extensions/llm'
require 'legion/settings'
require 'legion/logging'

# Stub the LegionIO host-runtime pieces that are not available in the provider
# gem's spec environment before loading Azure Foundry (the production host
# always loads them; a missing runtime must fail loud at require time, not
# here).
require_relative 'support/actor_runtime_stubs'

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

if defined?(Legion::Logging)
  # Ruby 4 treats File::NULL passed as a String as a logger with no logdev;
  # legion-logging then deliberately falls back to stdout. Keep a real IO
  # sink so the required JSON-to-file RSpec run remains zero-stdout.
  null_logger = Logger.new(StringIO.new)
  null_logger.level = Logger::DEBUG
  Legion::Logging.instance_variable_set(:@log, null_logger)
  Legion::Logging.instance_variable_set(
    :@current_settings,
    {
      level: :debug,
      format: :text,
      async: false,
      trace: false,
      trace_size: 0,
      extended: false,
      log_file: nil,
      log_stdout: false,
      include_pid: false,
      color: false
    }.freeze
  )
  Legion::Logging.instance_variable_set(:@configuration_generation, Legion::Logging.configuration_generation + 1)
end
