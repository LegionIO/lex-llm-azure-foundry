# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/settings/helper'
require 'legion/extensions/llm/azure_foundry/settings'
require 'legion/extensions/llm/azure_foundry/authentication'
require 'legion/extensions/llm/azure_foundry/model_catalog_parser'
require 'legion/extensions/llm/azure_foundry/provider'
require 'legion/extensions/llm/azure_foundry/version'

module Legion
  module Extensions
    module Llm
      # Named Azure instances participate in the shared provider lifecycle.
      module AzureFoundry
        extend Legion::Logging::Helper
        extend Legion::Settings::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :azure_foundry
        PROVIDER_KEYS = %i[api_version surface discovery_source deployments project_endpoint project_api_version
                           project_connection_name].freeze
        CREDENTIAL_KEYS = %i[api_key bearer_token broker project_bearer_token project_broker].freeze
        LEGACY_KEYS = %i[base_url api_base api_key bearer_token api_version surface].freeze

        def self.default_settings
          Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            discovery: Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:discovery],
            instance: Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance]
          )
        end

        def self.provider_class = Legion::Extensions::Llm::AzureFoundry::Provider

        def self.discover_instances
          validate_provider_settings!
          settings.fetch(:instances).each_with_object({}) do |(name, config), instances|
            next if config[:enabled] == false

            normalized = normalize_instance_config(config, name: name)
            next if normalized[:azure_foundry_endpoint].nil?
            next unless Legion::Extensions::Llm::AzureFoundry::Authentication.configured?(
              api_key: normalized[:azure_foundry_api_key], bearer_token: normalized[:azure_foundry_bearer_token],
              broker: normalized[:azure_foundry_broker]
            )

            instances[name.to_sym] = normalized
          end
        end

        def self.normalize_instance_config(config, name:)
          validate_instance_keys!(config: config)

          instance = Legion::Extensions::Llm::Utils.deep_merge(
            Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance], config
          )
          normalized = instance.except(:endpoint, :credentials, :provider)
          normalized[:instance_id] = name.to_s
          normalized[:azure_foundry_endpoint] = instance.fetch(:endpoint)
          project_instance_fields(normalized, instance.fetch(:provider), PROVIDER_KEYS)
          validate_project_credentials!(credentials: instance.fetch(:credentials))
          project_instance_fields(normalized, instance.fetch(:credentials), CREDENTIAL_KEYS)
          normalized
        end

        def self.validate_instance_keys!(config:)
          return unless config.keys.intersect?(LEGACY_KEYS)

          raise Legion::Extensions::Llm::ConfigurationError,
                'Azure instances use endpoint, credentials, and provider fields'
        end

        def self.normalize_discovery_source(value:)
          valid_type = value.is_a?(String) || value.is_a?(Symbol)
          unless valid_type && %i[model_info project declared].include?(value.to_sym)
            raise Legion::Extensions::Llm::ConfigurationError, 'unsupported provider.discovery_source'
          end

          value.to_sym
        end

        def self.validate_project_credentials!(credentials:)
          return unless credentials.key?(:project_api_key)

          raise Legion::Extensions::Llm::ConfigurationError,
                'credentials.project_api_key is unsupported; project discovery requires an Entra bearer or broker'
        end

        def self.validate_provider_settings!
          return unless settings[:endpoint] || LEGACY_KEYS.any? { |key| settings[key] }

          raise Legion::Extensions::Llm::ConfigurationError, 'Azure configuration must use named instances'
        end

        def self.project_instance_fields(normalized, values, keys)
          keys.each do |key|
            value = values.fetch(key)
            if %i[broker project_broker].include?(key)
              value = Legion::Extensions::Llm::AzureFoundry::Authentication.reference(broker: value)
            elsif key == :discovery_source
              value = normalize_discovery_source(value: value)
            end
            normalized[:"azure_foundry_#{key}"] = value
          end
        end

        private_class_method :normalize_instance_config, :project_instance_fields, :validate_provider_settings!,
                             :normalize_discovery_source, :validate_project_credentials!, :validate_instance_keys!

        Legion::Extensions::Llm::Configuration.register_provider_options(
          Legion::Extensions::Llm::AzureFoundry::Provider.configuration_options
        )
      end
    end
  end
end
