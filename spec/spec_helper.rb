# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/extensions/llm'

require 'legion/extensions/llm/azure_foundry'

# Load conformance kit from lex-llm gem's spec/ directory
# (spec/ ships in the gem but is NOT on the load path)
if Gem.loaded_specs['lex-llm']
  kit_path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path, 'spec/legion/extensions/llm/conformance')
  Dir[File.join(kit_path, '**', '*.rb')].each { |f| require f }
end

if defined?(Legion::Logging)
  null_logger = Logger.new(File::NULL)
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
