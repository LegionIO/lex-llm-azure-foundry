# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Builds sanitized lex-llm registry envelopes for Azure Foundry provider state.
        class RegistryEventBuilder
          def readiness(readiness)
            registry_event_class.public_send(
              readiness[:ready] ? :available : :unavailable,
              provider_offering(readiness),
              runtime: runtime_metadata,
              health: readiness_health(readiness),
              metadata: readiness_metadata(readiness)
            )
          end

          def model_available(model, readiness:)
            registry_event_class.available(
              model_offering(model),
              runtime: runtime_metadata,
              health: model_health(readiness),
              metadata: model_metadata(model)
            )
          end

          private

          def provider_offering(readiness)
            {
              provider_family: :azure_foundry,
              provider_instance: provider_instance,
              transport: :http,
              model: 'provider-readiness',
              usage_type: :inference,
              capabilities: [],
              health: readiness_health(readiness),
              metadata: { lex: :llm_azure_foundry, provider_readiness: true }
            }
          end

          def model_offering(model)
            metadata = model.metadata if model.respond_to?(:metadata)
            return metadata if metadata.is_a?(Hash) && metadata[:provider_family]

            {
              provider_family: :azure_foundry,
              provider_instance: provider_instance,
              transport: :http,
              model: model.id,
              usage_type: usage_type_for(model),
              capabilities: Array(model.capabilities).map(&:to_sym),
              limits: model_limits(model),
              metadata: { lex: :llm_azure_foundry, model_name: model.name }.compact
            }
          end

          def readiness_health(readiness)
            health = {
              ready: readiness[:ready] == true,
              status: readiness[:ready] ? :available : :unavailable,
              checked: readiness.dig(:health, :checked) != false
            }
            add_readiness_error(health, readiness[:health])
          end

          def add_readiness_error(health, source)
            error = source.is_a?(Hash) ? source : {}
            error_class = error[:error] || error['error']
            error_message = error[:message] || error['message']
            health[:error_class] = error_class if error_class
            health[:error] = error_message if error_message
            health
          end

          def model_health(readiness)
            ready = readiness.fetch(:ready, true) == true
            { ready:, status: ready ? :available : :degraded }
          end

          def readiness_metadata(readiness)
            {
              extension: :lex_llm_azure_foundry,
              provider: :azure_foundry,
              configured: readiness[:configured] == true,
              live: readiness[:live] == true
            }
          end

          def model_metadata(model)
            { extension: :lex_llm_azure_foundry, provider: :azure_foundry, model_type: model.type }
          end

          def runtime_metadata
            { node: provider_instance }
          end

          def model_limits(model)
            {
              context_window: model.context_window,
              max_output_tokens: model.max_output_tokens
            }.compact
          end

          def usage_type_for(model)
            model.type == 'embedding' ? :embedding : :inference
          end

          def provider_instance
            :azure_foundry
          end

          def registry_event_class
            ::Legion::Extensions::Llm::Routing::RegistryEvent
          end
        end
      end
    end
  end
end
