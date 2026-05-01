# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/azure_foundry/provider'
require 'legion/extensions/llm/azure_foundry/registry_event_builder'
require 'legion/extensions/llm/azure_foundry/registry_publisher'
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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            discovery: { enabled: true, live: false },
            instance: {
              endpoint: 'https://<resource>.services.ai.azure.com',
              api_version: '2024-05-01-preview',
              surface: :model_inference,
              tier: :frontier,
              transport: :http,
              credentials: {
                api_key: 'env://AZURE_INFERENCE_CREDENTIAL',
                bearer_token: 'env://AZURE_FOUNDRY_BEARER_TOKEN',
                entra_scope: 'https://cognitiveservices.azure.com/.default'
              },
              deployments: [],
              usage: { inference: true, embedding: true, token_counting: false },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::AzureFoundry::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::AzureFoundry::Provider)
