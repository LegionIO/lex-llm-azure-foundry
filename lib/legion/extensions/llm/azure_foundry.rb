# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/azure_foundry/provider'
require 'legion/extensions/llm/azure_foundry/version'
require_relative 'azure_foundry/actors/discovery_refresh'

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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: nil,
              tier: :frontier,
              transport: :http,
              credentials: {
                api_key: nil,
                bearer_token: nil
              },
              provider: {
                api_version: Provider::DEFAULT_API_VERSION,
                surface: nil,
                deployments: []
              },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed tools]
              }
            }
          )
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

        def self.discover_default_instance(instances) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          cfg = CredentialSources.setting(:extensions, :llm, :azure_foundry)
          return unless cfg.is_a?(Hash)

          endpoint = cfg[:endpoint] || cfg['endpoint'] || cfg[:base_url] || cfg['base_url'] || cfg[:api_base] ||
                     cfg['api_base']
          return if endpoint.nil? || endpoint.to_s.strip.empty?

          instances[:settings] = normalize_instance_config(cfg).merge(tier: :cloud)
        end

        def self.discover_named_instances(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :azure_foundry)
          return unless cfg.is_a?(Hash)

          named = cfg[:instances] || cfg['instances']
          return unless named.is_a?(Hash)

          named.each { |name, config| add_named_instance(instances, name, config) }
        end

        def self.add_named_instance(instances, name, config) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return unless config.is_a?(Hash)

          endpoint = config[:endpoint] || config['endpoint'] || config[:base_url] || config['base_url'] ||
                     config[:api_base] || config['api_base']
          return if endpoint.nil? || endpoint.to_s.strip.empty?

          instances[name.to_sym] = normalize_instance_config(config).merge(tier: :cloud)
        end

        def self.normalize_instance_config(config) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:azure_foundry_endpoint] ||= normalized.delete(:endpoint)
          normalized[:azure_foundry_endpoint] ||= normalized.delete(:base_url)
          normalized[:azure_foundry_endpoint] ||= normalized.delete(:api_base)
          normalized[:azure_foundry_api_key] ||= normalized.delete(:api_key)
          normalized[:azure_foundry_bearer_token] ||= normalized.delete(:bearer_token)
          normalized[:azure_foundry_api_version] ||= normalized.delete(:api_version)
          normalized[:azure_foundry_surface] ||= normalized.delete(:surface)
          normalized[:azure_foundry_deployments] ||= normalized.delete(:deployments)
          normalized.compact.except(:instances)
        end

        private_class_method :discover_default_instance, :discover_named_instances, :add_named_instance,
                             :normalize_instance_config

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
