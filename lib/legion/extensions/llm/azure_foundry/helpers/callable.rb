# frozen_string_literal: true

require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/azure_foundry/provider'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # Callable wrapper for an Azure Foundry provider instance. Implements
          # the fleet dispatch operations by delegating to the per-instance
          # AzureFoundry::Provider (errors propagate so
          # normalize_dispatch_error can classify them), plus the `disconnect`
          # and `normalize_dispatch_error(error:)` contracts required by
          # Inventory::CallableHandle and Routing::ProviderOutcome.
          #
          # The callable is the second canonical entry form (08 F2, 12/O05):
          # the shared lex-llm enforce_canonical_messages! helper runs at each
          # message-operation entry. The fleet passes `model:` as the
          # offering's model id (String) — it travels to the wire untouched
          # (08 F3, B4: no model re-derivation, no Model::Info fabrication).
          class Callable
            def initialize(instance_cfg:, logger:, provider: nil)
              @instance_cfg = instance_cfg
              @logger = logger
              @provider = provider
              @disconnected = false
            end

            def provider
              @provider ||= Legion::Extensions::Llm::AzureFoundry::Provider.new(@instance_cfg)
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @logger.debug { '[azure_foundry][callable] disconnected' }
            end

            def chat(messages, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              provider.chat(messages, model: model, **rest)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              provider.stream(messages, model: model, **rest, &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model: model, **rest)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              # The base heuristic ignores params (05 §2) — the fleet rest
              # folds into the params: slot rather than splatting into the
              # fixed base signature.
              provider.count_tokens(messages: messages, model: model, params: rest)
            end

            # D17: production dispatch raises Legion::Extensions::Llm::*Error
            # (ErrorMiddleware), not raw Faraday — the base
            # Provider#normalize_dispatch_error classifies those. On top, Azure
            # wire semantics supply two stronger signals: an explicit
            # EndpointDeactivated body (the ONLY instance_unavailable signal)
            # and a model-not-ready 503 body (request-local, not instance-down).
            def normalize_dispatch_error(error:)
              outcome = base_provider_outcome(error: error)
              return outcome_with_kind(outcome, :instance_unavailable) if explicit_endpoint_deactivated?(error: error)
              return outcome_with_kind(outcome, :model_not_ready) if model_not_ready_outcome?(outcome, error: error)
              return outcome_with_kind(outcome, :model_missing) if model_missing_outcome?(outcome, error: error)

              outcome
            end

            private

            # The base Provider#normalize_dispatch_error is a pure classifier
            # (it reads no instance state), so it is bound to an allocated
            # base instance — the callable classifies dispatch errors without
            # constructing a provider connection.
            def base_provider_outcome(error:)
              @base_classifier ||= Legion::Extensions::Llm::Provider.allocate
              @base_classifier.normalize_dispatch_error(error: error)
            end

            def outcome_with_kind(outcome, kind)
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: kind, reason: outcome.reason)
            end

            def request_local_kind?(kind)
              %i[overloaded provider_error].include?(kind)
            end

            def model_not_ready_outcome?(outcome, error:)
              model_not_ready?(error: error) && request_local_kind?(outcome.kind)
            end

            def model_missing_outcome?(outcome, error:)
              outcome.kind == :provider_error && error_status(error: error) == 404
            end

            # An explicit Azure endpoint-deactivation code is the ONLY signal
            # that justifies instance_unavailable. The body is read from the
            # Llm error's wrapped response (Faraday::Response in production,
            # Faraday::Env on raw error paths, or a Hash).
            def explicit_endpoint_deactivated?(error:)
              body = extract_error_body(error: error)
              body.include?('EndpointDeactivated') || body.include?('endpoint_deactivated')
            end

            def model_not_ready?(error:)
              body = extract_error_body(error: error).downcase
              body.include?('model not ready') || body.include?('deployment is warming up')
            end

            def extract_error_body(error:)
              response = error.respond_to?(:response) ? error.response : nil
              return response[:body].to_s if response.is_a?(Hash)
              return '' if response.nil?

              response.body.to_s
            end

            def error_status(error:)
              response = error.respond_to?(:response) ? error.response : nil
              return response[:status] if response.is_a?(Hash)
              return nil if response.nil?

              response.status
            end
          end
        end
      end
    end
  end
end
