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

        INSTANCE_DEFAULTS = {
          endpoint: nil,
          tier: :frontier,
          transport: :http,
          credentials: { api_key: nil, bearer_token: nil },
          provider: { api_version: Provider::DEFAULT_API_VERSION, surface: nil, deployments: [] },
          usage: { inference: true, embedding: true, image: false },
          limits: { concurrency: 4 },
          fleet: { enabled: false, respond_to_requests: false,
                   capabilities: %i[chat stream_chat embed tools] }
        }.freeze

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            discovery: { interval_seconds: 3600 },
            instance: INSTANCE_DEFAULTS
          )
        end

        def self.provider_class = Provider

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

          endpoint = extract_endpoint_from_cfg(cfg)
          return if endpoint.nil? || endpoint.to_s.strip.empty?

          instances[:settings] = normalize_instance_config(cfg).merge(tier: extract_tier_from_cfg(cfg))
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

          endpoint = extract_endpoint_from_cfg(config)
          return if endpoint.nil? || endpoint.to_s.strip.empty?

          instances[name.to_sym] = normalize_instance_config(config).merge(tier: extract_tier_from_cfg(config))
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          resolve_nested_credentials(normalized)
          resolve_nested_provider(normalized)
          promote_endpoint_aliases(normalized)
          promote_provider_aliases(normalized)
          normalized.compact.except(:instances)
        end

        def self.extract_endpoint_from_cfg(cfg)
          cfg[:endpoint] || cfg['endpoint'] || cfg[:base_url] || cfg['base_url'] ||
            cfg[:api_base] || cfg['api_base']
        end

        def self.extract_tier_from_cfg(cfg) = cfg[:tier] || cfg['tier'] || :cloud

        def self.promote_endpoint_aliases(normalized)
          normalized[:azure_foundry_endpoint] ||= normalized.delete(:endpoint)
          normalized[:azure_foundry_endpoint] ||= normalized.delete(:base_url)
          normalized[:azure_foundry_endpoint] ||= normalized.delete(:api_base)
        end

        def self.promote_provider_aliases(normalized)
          normalized[:azure_foundry_api_key] ||= normalized.delete(:api_key)
          normalized[:azure_foundry_bearer_token] ||= normalized.delete(:bearer_token)
          normalized[:azure_foundry_api_version] ||= normalized.delete(:api_version)
          normalized[:azure_foundry_surface] ||= normalized.delete(:surface)
          normalized[:azure_foundry_deployments] ||= normalized.delete(:deployments)
        end

        # Nested `credentials: { api_key:, bearer_token: }` is the canonical shape
        # (matches default_settings and every other lex-llm-* provider). Flat keys
        # remain accepted as aliases.
        def self.resolve_nested_credentials(normalized)
          creds = normalized.delete(:credentials)
          return unless creds.is_a?(Hash)

          creds = creds.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:azure_foundry_api_key] ||= creds[:api_key]
          normalized[:azure_foundry_bearer_token] ||= creds[:bearer_token]
        end

        # Nested `provider: { api_version:, surface:, deployments: }` is the
        # canonical shape from default_settings. Flat keys remain accepted.
        def self.resolve_nested_provider(normalized)
          prov = normalized.delete(:provider)
          return unless prov.is_a?(Hash)

          prov = prov.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:azure_foundry_api_version] ||= prov[:api_version]
          normalized[:azure_foundry_surface] ||= prov[:surface]
          normalized[:azure_foundry_deployments] ||= prov[:deployments]
        end

        private_class_method :discover_default_instance, :discover_named_instances, :add_named_instance,
                             :normalize_instance_config, :resolve_nested_credentials, :resolve_nested_provider,
                             :extract_endpoint_from_cfg, :extract_tier_from_cfg,
                             :promote_endpoint_aliases, :promote_provider_aliases

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
