# frozen_string_literal: true

require 'uri'
require 'legion/extensions/llm/azure_foundry/endpoint'
require 'legion/extensions/llm/azure_foundry/settings'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # Azure connection hooks used by the shared discovery lifecycle.
          module EndpointAccess
            def catalog_base_url(instance_cfg:, **) = endpoint_for(instance_cfg: instance_cfg).base_url
            def catalog_path(instance_cfg:, **) = endpoint_for(instance_cfg: instance_cfg).catalog_path

            def auth_token(instance_cfg:, **)
              token = instance_cfg[:azure_foundry_api_key]
              token if credential_string?(token)
            end

            def apply_auth_headers(faraday:, instance_cfg:, **)
              key = instance_cfg[:azure_foundry_api_key]
              token = instance_cfg[:azure_foundry_bearer_token]
              faraday.headers['api-key'] = key if credential_string?(key)
              faraday.headers['Authorization'] = "Bearer #{token}" if credential_string?(token)
            end

            def derive_physical_id(instance_cfg:, **)
              endpoint = instance_cfg[:azure_foundry_endpoint]
              unless credential_string?(endpoint)
                raise ArgumentError, 'azure_foundry_endpoint is required to derive the physical id'
              end

              host_port = extract_host_port(url: endpoint)
              key = instance_cfg[:azure_foundry_api_key]
              return host_port unless credential_string?(key)

              "#{host_port}/ak:#{Legion::Extensions::Llm::CredentialSources.credential_fingerprint(key)}"
            end

            def extract_host_port(url:, **)
              uri = URI.parse(url.to_s)
              raise ArgumentError, 'Azure Foundry endpoint must have a host' unless uri.host

              "#{uri.host.downcase}:#{uri.port}"
            end

            private

            def surface_for(instance_cfg)
              (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] ||
                Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance][:provider][:surface]).to_sym
            end

            def endpoint_for(instance_cfg:)
              defaults = Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance][:provider]
              version = instance_cfg[:azure_foundry_api_version] || instance_cfg[:api_version] || defaults[:api_version]
              Legion::Extensions::Llm::AzureFoundry::Endpoint.new(
                endpoint: instance_cfg[:azure_foundry_endpoint], surface: surface_for(instance_cfg),
                api_version: version
              )
            end

            def credential_string?(value) = value.is_a?(String) && !value.strip.empty?
          end
        end
      end
    end
  end
end
