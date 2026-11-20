# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/azure_foundry/settings'
require 'legion/extensions/llm/azure_foundry/authentication'
require 'legion/extensions/llm/azure_foundry/endpoint'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Azure supplies protocol URLs and authentication. Completion, streaming,
        # embeddings, canonical enforcement, and inventory reads are shared.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible

          def self.slug = 'azure_foundry'
          def self.default_transport = :http
          def self.default_tier = Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance][:tier]
          def self.configuration_requirements = %i[azure_foundry_endpoint azure_foundry_surface]

          def self.configuration_options
            %i[
              azure_foundry_endpoint azure_foundry_api_key azure_foundry_bearer_token
              azure_foundry_api_version azure_foundry_surface azure_foundry_project_endpoint
              azure_foundry_project_api_version azure_foundry_project_bearer_token
              azure_foundry_broker azure_foundry_project_broker azure_foundry_project_connection_name
            ]
          end

          def stream_usage_supported? = true
          def api_base = azure_endpoint.base_url

          def headers
            identity_headers.merge(Legion::Extensions::Llm::AzureFoundry::Authentication.headers(
                                     api_key: config.azure_foundry_api_key,
                                     bearer_token: config.azure_foundry_bearer_token,
                                     broker: config.azure_foundry_broker, purpose: :inference
                                   ))
          end

          def completion_url = azure_endpoint.path(operation: 'chat/completions')
          def chat_url = completion_url
          def stream_url = completion_url
          def models_url = azure_endpoint.catalog_path
          def embedding_url(**) = azure_endpoint.path(operation: 'embeddings')
          def health_url = models_url

          # Azure's catalog is a transport/authentication probe, not a health
          # document. Translate its status for the shared health renderer.
          def readiness(live: false)
            baseline = super(live: false)
            return baseline unless live

            status = connection.get(health_url).status
            baseline.merge(
              live: true, ready: status == 200,
              health: { checked: true, status: status == 200 ? 'healthy' : 'unhealthy', status_code: status }
            )
          end

          private

          def azure_endpoint
            Legion::Extensions::Llm::AzureFoundry::Endpoint.new(
              endpoint: config.azure_foundry_endpoint,
              surface: config.azure_foundry_surface,
              api_version: config.azure_foundry_api_version
            )
          end
        end
      end
    end
  end
end
