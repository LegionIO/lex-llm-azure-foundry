# frozen_string_literal: true

require 'uri'
require 'legion/extensions/llm/azure_foundry/endpoint'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # A configured instance owns one endpoint and callable. A project
          # connection is a selector for that instance, never a dispatch router.
          module ProjectConnection
            private

            def project_connection_name(instance_cfg:)
              name = instance_cfg[:azure_foundry_project_connection_name]
              unless name.nil? || name.is_a?(String)
                raise Legion::Extensions::Llm::ConfigurationError, 'provider.project_connection_name must be a string'
              end

              name.to_s.strip.empty? ? nil : name.strip
            end

            def project_connection_matches?(instance_cfg:, connection:, endpoint:, version:)
              name = project_connection_name(instance_cfg: instance_cfg)
              return true unless name

              path = URI.encode_www_form_component(name).gsub('+', '%20')
              url = "#{endpoint}/connections/#{path}?#{URI.encode_www_form('api-version' => version)}"
              response = connection.get(url)
              unless response.status == 200
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      "project connection metadata returned HTTP #{response.status}"
              end

              connection_target_matches?(body: catalog_body(response), name: name, instance_cfg: instance_cfg)
            end

            def connection_target_matches?(body:, name:, instance_cfg:)
              unless body.is_a?(Hash) && body[:name] == name && body[:type].is_a?(String)
                raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                      'invalid Azure project connection identity'
              end
              matches = body[:type] == 'AzureOpenAI' && surface_for(instance_cfg) == :openai_v1 &&
                        connection_endpoint(body[:target]) == connection_endpoint(instance_cfg[:azure_foundry_endpoint])
              unless matches
                log.warn("[azure_foundry][discovery] action=connection_binding_mismatch connection=#{name} offerings=0")
              end
              matches
            end

            def connection_endpoint(value)
              base = Legion::Extensions::Llm::AzureFoundry::Endpoint.new(
                endpoint: value, surface: :openai_v1, api_version: nil
              ).base_url
              uri = URI.parse(base)
              [uri.scheme, uri.host.downcase, uri.port, uri.path]
            rescue ArgumentError, URI::InvalidURIError => e
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'invalid Azure project connection endpoint', cause: e
            end
          end
        end
      end
    end
  end
end
