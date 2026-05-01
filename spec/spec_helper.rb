# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'

# register_provider_options is defined in the full runtime but not in the
# standalone Configuration class shipped with lex-llm.  Patch it in so the
# provider file can register its config options during require.
unless Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
  Legion::Extensions::Llm::Configuration.define_singleton_method(:register_provider_options) do |keys|
    Array(keys).each { |k| option(k) }
  end
end

require 'legion/extensions/llm/azure_foundry'
