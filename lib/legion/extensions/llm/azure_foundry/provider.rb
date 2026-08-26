# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/extensions/llm'
require 'legion/extensions/llm/azure_foundry/model_catalog_parser'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Capability predicates inferred from catalog metadata and model
        # naming. Naming is a hint only — it never overrides explicit catalog
        # facts.
        module Capabilities
          module_function

          def chat?(model) = !embeddings?(model)
          def streaming?(model) = chat?(model)
          def functions?(model) = chat?(model)
          def vision?(model) = chat?(model) && model_id(model).match?(/(gpt-4|gpt-5|llava|vision|phi-3.5)/i)
          def embeddings?(model) = model_id(model).match?(/embed/i)

          def critical_capabilities_for(model)
            [
              ('streaming' if streaming?(model)),
              ('function_calling' if functions?(model)),
              ('vision' if vision?(model)),
              ('embeddings' if embeddings?(model))
            ].compact
          end

          def model_id(model)
            return model.id.to_s if model.respond_to?(:id)

            model.to_s
          end
        end

        # Class-level methods for Provider — exposed via extend.
        module ProviderClassMethods
          def slug = 'azure_foundry'
          def default_transport = :http
          def default_tier = :cloud
          def configuration_requirements = %i[azure_foundry_endpoint]
          def capabilities = Capabilities

          def configuration_options
            %i[
              azure_foundry_endpoint azure_foundry_api_key azure_foundry_bearer_token
              azure_foundry_api_version azure_foundry_surface
            ]
          end
        end

        # Public dispatch methods — chat, stream, embed. count_tokens
        # inherits the base heuristic (Integer estimate, 05 §2) — the
        # operation's support is carried by the SSOT data plane (writer
        # operation evidence + WorkerExecution.require_supported!), not by
        # a per-call artifact.
        #
        # Canonical boundary (N x N law): the shared lex-llm
        # enforce_canonical_messages! helper runs at every message-operation
        # entry (08 F2, 12/O05 — one shared helper, called at every
        # operation entry). Pipeline dispatch (direct SelectionDispatch,
        # fleet worker rehydration) delivers Canonical::Message objects and
        # nothing else; plain Hashes are the bypass class (the 2026-08-19
        # incident) — rejected loudly, never silently coerced. The model
        # travels as the Selection-derived String, untouched (08 F3, B4);
        # sampling params travel as Canonical::Params (05 O4).
        module ProviderDispatchMethods
          def chat(messages, model:, **options)
            enforce_canonical_messages!(messages)
            log.info { "chat request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}),
                               model: model,
                               params: canonical_params(options), tool_prefs: options[:tool_prefs])
          end

          def stream(messages, model:, **options, &)
            enforce_canonical_messages!(messages)
            log.info { "stream request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}),
                               model: model,
                               params: canonical_params(options), tool_prefs: options[:tool_prefs], &)
          end

          def embed(text:, model:, **options)
            enforce_model_allowed!(model)
            log.info { "embed request model=#{model}" }
            payload = render_embedding_payload(text, model: model_id(model), dimensions: options[:dimensions])
            payload[:input_type] = options[:input_type] if options[:input_type]
            response = connection.post(embedding_url(model:), payload)
            parse_embedding_response(response, model: model_id(model), text:)
          end
        end

        # Azure AI Foundry and Azure OpenAI hosted provider surface.
        #
        # Offerings are produced ONLY by the discovery actor's writer path
        # (OfferingDraft + Registry publication, 07 C1-C5); the base read
        # path discover_offerings serves the activated inventory offerings
        # from the Registry snapshot (07 C5). The legacy offering
        # production path (and its capability-policy cascade) is gone.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          extend ProviderClassMethods
          include ProviderDispatchMethods

          DEFAULT_API_VERSION = '2024-05-01-preview'
          MODEL_INFERENCE_SURFACE = :model_inference
          OPENAI_V1_SURFACE = :openai_v1

          def stream_usage_supported? = true

          def api_base
            endpoint = config.azure_foundry_endpoint.to_s.sub(%r{/*\z}, '')
            return "#{endpoint}/openai/v1" if surface == OPENAI_V1_SURFACE && !endpoint.end_with?('/openai/v1')
            return endpoint.delete_suffix('/models') if surface == MODEL_INFERENCE_SURFACE

            endpoint
          end

          def headers
            identity_headers.merge({ 'api-key' => config.azure_foundry_api_key,
                                     'Authorization' => bearer_header }.compact)
          end

          def completion_url = path_for('chat/completions')
          def chat_url = completion_url
          def stream_url = completion_url
          def models_url = surface == MODEL_INFERENCE_SURFACE ? path_for('info') : path_for('models')
          def embedding_url(**) = path_for('embeddings')
          def health_url = models_url

          def health(live: false)
            log.info { "checking health live=#{live} at #{api_base}" }
            baseline = health_baseline(live)
            return baseline.merge(checked: false) unless live

            response = connection.get(health_url)
            baseline.merge(checked: true, ready: true, status: 'healthy', raw: response.body)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'azure_foundry.health')
            baseline.merge(checked: true, ready: false, status: 'unhealthy',
                           error: e.class.name, message: e.message)
          end

          def readiness(live: false)
            log.info { "checking readiness live=#{live} at #{api_base}" }
            health(live: live).merge(local: false, remote: true, endpoints: endpoint_manifest)
          end

          def model_id(model)
            model.respond_to?(:id) ? model.id : model.to_s
          end

          private

          def surface = (config.azure_foundry_surface || MODEL_INFERENCE_SURFACE).to_sym

          def health_baseline(live)
            ready = configured?
            { provider: :azure_foundry, instance_id: provider_instance_id, configured: ready,
              ready: ready, live: live, status: ready ? 'healthy' : 'unhealthy',
              api_base: api_base, surface: surface }
          end

          # Fleet dispatch hands the canonical param spellings as flat kwargs
          # (the client translators already translated the wire dialect,
          # 03 O03a). One canonical home for the complete funnel:
          # Canonical::Params (05 O4 — temperature lives only there).
          def canonical_params(options)
            Legion::Extensions::Llm::Canonical::Params.from_hash(
              options.slice(*Legion::Extensions::Llm::Canonical::Params.members)
            )
          end

          def api_version = config.azure_foundry_api_version || DEFAULT_API_VERSION

          def path_for(path)
            prefix = surface == MODEL_INFERENCE_SURFACE ? 'models/' : ''
            suffix = surface == MODEL_INFERENCE_SURFACE ? "?api-version=#{api_version}" : ''
            "#{prefix}#{path}#{suffix}"
          end

          def bearer_header
            token = config.azure_foundry_bearer_token
            token ? "Bearer #{token}" : nil
          end
        end
      end
    end
  end
end
