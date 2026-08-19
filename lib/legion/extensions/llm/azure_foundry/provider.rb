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
          def registry_publisher = AzureFoundry.registry_publisher

          def configuration_options
            %i[
              azure_foundry_endpoint azure_foundry_api_key azure_foundry_bearer_token
              azure_foundry_api_version azure_foundry_surface
            ]
          end
        end

        # Public dispatch methods — chat, stream, embed, count_tokens.
        #
        # Canonical boundary (N x N law): pipeline dispatch delivers
        # Canonical::Message objects; the provider-native Chat facade
        # delivers lex-llm Message objects. Both are object shapes the
        # inherited OpenAI-compatible render duck-types (.role/.content/
        # .tool_calls) and pass through unchanged. Plain Hashes are the
        # bypass class (the 2026-08-19 incident) — reject loudly, never
        # silently coerce.
        module ProviderDispatchMethods
          def chat(messages:, model:, **options)
            enforce_message_boundary!(messages)
            log.info { "chat request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}), temperature: options[:temperature],
                               model: model_info(model, max_tokens: options[:max_tokens]),
                               params: options.fetch(:params, {}), tool_prefs: options[:tool_prefs])
          end

          def stream(messages:, model:, **options, &)
            enforce_message_boundary!(messages)
            log.info { "stream request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}), temperature: options[:temperature],
                               model: model_info(model, max_tokens: options[:max_tokens]),
                               params: options.fetch(:params, {}), tool_prefs: options[:tool_prefs], &)
          end

          def embed(text:, model:, **options)
            log.info { "embed request model=#{model}" }
            payload = Utils.deep_merge(
              render_embedding_payload(text, model: model_id(model), dimensions: options[:dimensions]),
              options.fetch(:params, {})
            )
            payload[:input_type] = options[:input_type] if options[:input_type]
            response = connection.post(embedding_url(model:), payload)
            parse_embedding_response(response, model: model_id(model), text:)
          end

          def count_tokens(messages:, model:, **)
            enforce_message_boundary!(messages)
            {
              provider_family: :azure_foundry, model: model_id(model), supported: false,
              reason: 'Azure AI Foundry REST docs do not define a portable token-counting endpoint.',
              estimated_input_characters: messages.sum { |m| m.content.to_s.length }
            }
          end
        end

        # Live model-catalog discovery. The catalog is fetched from the
        # surface's discovery endpoint (Provider#models_url) and parsed
        # through ModelCatalogParser — the same module the SSOT v3 discovery
        # actor uses, so the two paths cannot drift. No instance config
        # participates: whatever the endpoint reports is the offering set.
        module ProviderCatalogHelpers
          def parse_list_models_response(response, _provider, _capabilities)
            ModelCatalogParser.model_entries(catalog_body(response)).filter_map do |entry|
              model_id = ModelCatalogParser.model_id_for(entry)
              next if model_id.to_s.strip.empty?

              model_info_from_catalog_entry(entry, model_id)
            end
          end

          private

          def catalog_body(response)
            body = response.body
            return body unless body.is_a?(String)
            return body if body.strip.empty?

            Legion::JSON.parse(body, symbolize_names: false)
          end

          def model_info_from_catalog_entry(entry, model_id)
            base_name = ModelCatalogParser.base_model_name_for(entry)
            family = ModelCatalogParser.model_family_for(base_name || model_id)
            max_output = entry['max_output_tokens'] || entry[:max_output_tokens]
            max_output = max_output.to_i if max_output
            Legion::Extensions::Llm::Model::Info.new(
              id: model_id,
              name: base_name || model_id,
              provider: :azure_foundry,
              family: family,
              capabilities: Capabilities.critical_capabilities_for(model_id),
              context_length: ModelCatalogParser.context_window_for(entry),
              # Model::Info#max_output_tokens reads metadata[:max_output_tokens].
              metadata: { raw: entry, max_output_tokens: max_output }.compact
            )
          end
        end

        # Offering construction from a live-discovered Model::Info. Capability
        # policy resolution mirrors the other providers: real catalog facts
        # (streaming/tools/vision/embedding) feed CapabilityPolicy with the
        # base-class provider/instance/model settings cascade.
        module ProviderOfferingHelpers
          private

          def offering_from_model(model, health: {})
            policy = resolve_catalog_capability_policy(model)
            family = model.family&.to_sym

            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :azure_foundry,
              instance_id: provider_instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model.id,
              canonical_model_alias: model.name,
              model_family: family,
              usage_type: model.embedding? ? :embedding : :inference,
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: {
                context_window: model.context_length,
                max_output_tokens: model.max_output_tokens
              }.compact,
              health: health,
              metadata: { model_family: family }.compact
            )
          end

          def resolve_catalog_capability_policy(model)
            real = Array(model.capabilities).to_h do |cap|
              [cap.to_s.downcase.tr('-', '_').tr(' ', '_').to_sym, true]
            end
            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: real,
              provider_catalog: {},
              probe: {},
              provider_envelope: { streaming: true },
              provider_config: provider_capability_config,
              instance_config: instance_capability_config,
              model_config: model_capability_config(model.id)
            )
          end
        end

        # Azure AI Foundry and Azure OpenAI hosted provider surface.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          extend ProviderClassMethods
          include ProviderCatalogHelpers
          include ProviderOfferingHelpers
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

          # Canonical boundary (N x N law). Pipeline dispatch delivers
          # Canonical::Message objects; the provider-native Chat facade
          # delivers lex-llm Message objects. Both are object shapes the
          # inherited render duck-types, so they pass through unchanged.
          # Anything else — the plain-Hash bypass class from the
          # 2026-08-19 incident — is rejected loudly, never coerced.
          def enforce_message_boundary!(messages)
            Array(messages).each do |message|
              next if message.is_a?(Legion::Extensions::Llm::Canonical::Message)
              next if message.is_a?(Legion::Extensions::Llm::Message)

              raise ArgumentError,
                    "azure_foundry provider input must be Canonical::Message objects, got #{message.class} — " \
                    'non-canonical message shapes must not cross the dispatch boundary'
            end
            messages
          end

          def surface = (config.azure_foundry_surface || MODEL_INFERENCE_SURFACE).to_sym

          def health_baseline(live)
            ready = configured?
            { provider: :azure_foundry, instance_id: provider_instance_id, configured: ready,
              ready: ready, live: live, status: ready ? 'healthy' : 'unhealthy',
              api_base: api_base, surface: surface }
          end

          def model_info(model, max_tokens: nil)
            return model if model.respond_to?(:id) && max_tokens.nil?

            Legion::Extensions::Llm::Model::Info.new(id: model_id(model), provider: :azure_foundry,
                                                     max_output_tokens: max_tokens)
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
