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
        extend Legion::Extensions::Llm::AutoRegistration

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

        def self.discover_instances
          instances = {}
          discover_default_instance(instances)
          discover_named_instances(instances)
          instances
        end

        def self.discover_default_instance(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :azure_foundry)
          return unless cfg.is_a?(Hash)

          endpoint = cfg[:endpoint] || cfg['endpoint']
          return if endpoint.nil? || endpoint.to_s.strip.empty?

          instances[:settings] = cfg.except(:instances, 'instances').merge(tier: :cloud)
        end

        def self.discover_named_instances(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :azure_foundry)
          return unless cfg.is_a?(Hash)

          named = cfg[:instances] || cfg['instances']
          return unless named.is_a?(Hash)

          named.each { |name, config| add_named_instance(instances, name, config) }
        end

        def self.add_named_instance(instances, name, config)
          return unless config.is_a?(Hash)

          endpoint = config[:endpoint] || config['endpoint']
          return if endpoint.nil? || endpoint.to_s.strip.empty?

          instances[name.to_sym] = config.merge(tier: :cloud)
        end

        private_class_method :discover_default_instance, :discover_named_instances, :add_named_instance

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end

Legion::Extensions::Llm::AzureFoundry.register_discovered_instances
