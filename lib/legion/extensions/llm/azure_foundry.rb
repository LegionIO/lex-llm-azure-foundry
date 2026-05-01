# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/azure_foundry/provider'
require 'legion/extensions/llm/azure_foundry/version'

module Legion
  module Extensions
    module Llm
      # Azure AI Foundry provider extension namespace.
      module AzureFoundry
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper

        PROVIDER_FAMILY = :azure_foundry

        def self.default_settings
          {
            enabled: false,
            default_model: nil,
            endpoint: nil,
            api_key: nil,
            bearer_token: nil,
            api_version: '2024-05-01-preview',
            surface: nil,
            deployments: [],
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 3600,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end

        def self.registry_publisher
          @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: PROVIDER_FAMILY)
        end

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
