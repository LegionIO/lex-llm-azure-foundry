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

          # Immutable vendor facts, keyed by exact model/version/deployment type.
          # Standard/regional and provisioned limits must not be inferred from
          # the GlobalStandard tuples. See README's vendor metadata references.
          MODEL_METADATA = {
            %w[gpt-4o-mini 2024-07-18 GlobalStandard].freeze => {
              context_window: 128_000, max_output_tokens: 16_384,
              capabilities: { completion: true, streaming: true, tools: true, vision: true }.freeze
            }.freeze,
            %w[gpt-4.1 2025-04-14 GlobalStandard].freeze => {
              context_window: 1_047_576, max_output_tokens: 32_768,
              capabilities: { completion: true, streaming: true, tools: true, vision: true }.freeze
            }.freeze
          }.freeze

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
              azure_foundry_discovery_source azure_foundry_deployments
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

          # Only structured Azure evidence can refine the shared error kind.
          def normalize_dispatch_error(error:)
            outcome = super
            return outcome unless %i[provider_error overloaded].include?(outcome.kind)

            status, body = error_response(error: error)
            kind = azure_error_kind(status: status, code: error_code(body: body))
            kind ? outcome.with(kind: kind) : outcome
          end

          private

          def error_response(error:)
            return [] unless error.is_a?(Legion::Extensions::Llm::Error) || error.is_a?(Faraday::Error)

            response = error.response
            case response
            when Hash then [response[:status], response[:body]]
            when Faraday::Response, Faraday::Env, Legion::Extensions::Llm::ErrorMiddleware::ResponseWithBody
              [response.status, response.body]
            else []
            end
          end

          def error_code(body:)
            body = Legion::JSON.load(body) if body.is_a?(String) && !body.empty?
            return unless body.is_a?(Hash)

            detail = Legion::Extensions::Llm::Utils.deep_symbolize_keys(body)[:error]
            detail[:code] if detail.is_a?(Hash)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, operation: 'azure_foundry.provider.error_code')
            nil
          end

          def azure_error_kind(status:, code:)
            case [status, code]
            when [503, 'EndpointDeactivated'] then :instance_unavailable
            when [503, 'ModelNotReady'] then :model_not_ready
            when [404, 'DeploymentNotFound'] then :model_missing
            end
          end

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
