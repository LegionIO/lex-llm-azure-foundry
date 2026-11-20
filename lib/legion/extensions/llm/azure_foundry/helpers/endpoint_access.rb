# frozen_string_literal: true

require 'uri'
require 'digest'
require 'legion/extensions/llm/azure_foundry/endpoint'
require 'legion/extensions/llm/azure_foundry/settings'
require 'legion/extensions/llm/azure_foundry/authentication'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # Azure connection hooks used by the shared discovery lifecycle.
          module EndpointAccess
            def catalog_base_url(instance_cfg:, **) = endpoint_for(instance_cfg: instance_cfg).base_url
            def catalog_path(instance_cfg:, **) = endpoint_for(instance_cfg: instance_cfg).catalog_path

            def apply_auth_headers(faraday:, instance_cfg:, **)
              Legion::Extensions::Llm::AzureFoundry::Authentication.install_discovery(
                faraday: faraday, api_key: instance_cfg[:azure_foundry_api_key],
                bearer_token: instance_cfg[:azure_foundry_bearer_token], broker: instance_cfg[:azure_foundry_broker]
              )
            end

            def derive_physical_id(instance_cfg:, **)
              endpoint = instance_cfg[:azure_foundry_endpoint]
              unless credential_string?(endpoint)
                raise ArgumentError, 'azure_foundry_endpoint is required to derive the physical id'
              end

              host_port = extract_host_port(url: endpoint)
              key = instance_cfg[:azure_foundry_api_key]
              if credential_string?(key)
                host_port = "#{host_port}/ak:#{Legion::Extensions::Llm::CredentialSources.credential_fingerprint(key)}"
              end

              "#{host_port}/binding:#{binding_fingerprint(instance_cfg: instance_cfg)}"
            end

            def extract_host_port(url:, **)
              uri = URI.parse(url.to_s)
              raise ArgumentError, 'Azure Foundry endpoint must have a host' unless uri.host

              "#{uri.host.downcase}:#{uri.port}"
            end

            private

            def authenticated_catalog(instance_cfg:)
              response = catalog_response(instance_cfg: instance_cfg)
              unless response.status == 200
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      "catalog fetch returned HTTP #{response.status}"
              end
              catalog_body(response)
            end

            def catalog_response(instance_cfg:, health: false)
              limits = settings[:discovery]
              conn = build_connection(
                base_url: catalog_base_url(instance_cfg: instance_cfg), instance_cfg: instance_cfg,
                timeout: limits[health ? :health_timeout : :request_timeout],
                open_timeout: limits[health ? :health_open_timeout : :open_timeout]
              )
              conn.get(catalog_path(instance_cfg: instance_cfg))
            end

            def catalog_body(response)
              body = response.body
              body.is_a?(String) ? Legion::JSON.load(body) : body
            end

            # Configured binding changes must reclaim the callable. Rotating
            # broker lease contents are deliberately absent from this identity.
            def binding_fingerprint(instance_cfg:)
              endpoint = endpoint_for(instance_cfg: instance_cfg)
              uri = URI.parse(endpoint.base_url)
              binding = {
                endpoint: [uri.scheme, uri.host.downcase, uri.port, uri.path], surface: endpoint.surface,
                api_version: endpoint.api_version
              }.merge(binding_details(instance_cfg: instance_cfg))
              Digest::SHA256.hexdigest(Legion::JSON.dump(binding))
            end

            def binding_details(instance_cfg:)
              binding = {
                project_endpoint: instance_cfg[:azure_foundry_project_endpoint],
                project_connection: instance_cfg[:azure_foundry_project_connection_name],
                broker: Legion::Extensions::Llm::AzureFoundry::Authentication.reference(
                  broker: instance_cfg[:azure_foundry_broker]
                ),
                project_broker: Legion::Extensions::Llm::AzureFoundry::Authentication.reference(
                  broker: instance_cfg[:azure_foundry_project_broker]
                )
              }.compact
              token = instance_cfg[:azure_foundry_bearer_token]
              if credential_string?(token)
                binding[:bearer] =
                  Legion::Extensions::Llm::CredentialSources.credential_fingerprint(token)
              end
              binding
            end

            def surface_for(instance_cfg)
              instance_cfg.fetch(:azure_foundry_surface).to_sym
            end

            def endpoint_for(instance_cfg:)
              Legion::Extensions::Llm::AzureFoundry::Endpoint.new(
                endpoint: instance_cfg[:azure_foundry_endpoint], surface: surface_for(instance_cfg),
                api_version: instance_cfg[:azure_foundry_api_version]
              )
            end

            def credential_string?(value) = value.is_a?(String) && !value.strip.empty?
          end
        end
      end
    end
  end
end
