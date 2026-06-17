# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Azure AI Foundry and Azure OpenAI hosted provider surface.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          include Legion::Extensions::Llm::Provider::OpenAICompatible

          DEFAULT_API_VERSION = '2024-05-01-preview'
          MODEL_INFERENCE_SURFACE = :model_inference
          OPENAI_V1_SURFACE = :openai_v1

          class << self
            def slug = 'azure_foundry'
            def default_transport = :http
            def default_tier = :cloud
            def configuration_requirements = %i[azure_foundry_endpoint]

            def configuration_options
              %i[
                azure_foundry_endpoint
                azure_foundry_api_key
                azure_foundry_bearer_token
                azure_foundry_api_version
                azure_foundry_surface
                azure_foundry_deployments
              ]
            end

            def capabilities = Capabilities

            def registry_publisher
              AzureFoundry.registry_publisher
            end

            def resolve_model_id(model_id, config: nil)
              deployment = deployment_config(model_id, config:)
              value_for(deployment, :deployment) || value_for(deployment, :model) || model_id.to_s
            end

            def deployment_config(model_id, config:)
              deployments = config&.azure_foundry_deployments
              entries = normalize_deployments(deployments)
              entries.find do |entry|
                [value_for(entry, :deployment), value_for(entry, :model), value_for(entry, :canonical_model_alias)]
                  .compact.map(&:to_s).include?(model_id.to_s)
              end
            end

            def normalize_deployments(deployments)
              case deployments
              when Hash
                deployments.map do |name, metadata|
                  value = metadata.to_h
                  value[:deployment] ||= name
                  value
                end
              else
                Array(deployments).map { |deployment| normalize_deployment_entry(deployment) }
              end
            end

            private

            def normalize_deployment_entry(deployment)
              deployment.is_a?(Hash) ? deployment.dup : { deployment: deployment.to_s }
            end

            def value_for(hash, key)
              return nil unless hash.respond_to?(:key?)

              hash[key] || hash[key.to_s]
            end
          end

          # Capability predicates inferred from deployment metadata and model naming.
          module Capabilities
            module_function

            def chat?(model) = !embeddings?(model)
            def streaming?(model) = chat?(model)
            def functions?(model) = chat?(model)
            def vision?(model) = chat?(model) && model_id(model).match?(/(gpt-4|gpt-5|llava|vision|phi-3.5)/i)
            def embeddings?(model) = usage_type(model) == :embedding || model_id(model).match?(/embed/i)

            def critical_capabilities_for(model)
              [
                ('streaming' if streaming?(model)),
                ('function_calling' if functions?(model)),
                ('vision' if vision?(model)),
                ('embeddings' if embeddings?(model))
              ].compact
            end

            def model_id(model)
              return hash_model_id(model) if model.is_a?(Hash)

              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end

            def hash_model_id(model)
              %i[canonical_model_alias model deployment].each do |key|
                value = model[key] || model[key.to_s]
                return value.to_s if value
              end
            end

            def usage_type(model)
              return nil unless model.is_a?(Hash)

              value = model[:usage_type] || model['usage_type'] || model[:type] || model['type']
              value&.to_sym
            end
          end

          def stream_usage_supported? = true

          def api_base
            endpoint = config.azure_foundry_endpoint.to_s.sub(%r{/*\z}, '')
            return "#{endpoint}/openai/v1" if surface == OPENAI_V1_SURFACE && !endpoint.end_with?('/openai/v1')
            return endpoint.delete_suffix('/models') if surface == MODEL_INFERENCE_SURFACE

            endpoint
          end

          def headers
            identity_headers.merge({
              'api-key' => config.azure_foundry_api_key,
              'Authorization' => bearer_header
            }.compact)
          end

          def completion_url = path_for('chat/completions')
          def chat_url = completion_url
          def stream_url = completion_url
          def models_url = path_for('info')
          def embedding_url(**) = path_for('embeddings')
          def health_url = models_url

          def discover_offerings(live: false, **filters)
            log.info { "discovering offerings live=#{live} from #{api_base}" }
            offerings = filter_offerings(allowed_offerings, **filters)
            return offerings unless live

            offerings.map do |offering|
              with_live_metadata(offering)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'azure_foundry.discover_offerings')
              with_health(offering, ready: false, checked: true, error: e)
            end
          end

          def offering_for(model:, model_family: nil, canonical_model_alias: nil, instance_id: :default, # rubocop:disable Metrics/ParameterLists
                           usage_type: nil, **metadata)
            deployment = self.class.deployment_config(model, config:)
            model_id = self.class.resolve_model_id(model, config:)
            configured_family = value_for(deployment, :model_family)
            configured_alias = value_for(deployment, :canonical_model_alias)

            build_offering(
              model: model_id,
              instance_id: instance_id,
              model_family: normalize_family(model_family || configured_family || infer_model_family(model_id)),
              canonical_model_alias: canonical_model_alias || configured_alias,
              usage_type: usage_type || value_for(deployment, :usage_type) || usage_type_for(model_id),
              metadata: metadata.merge(deployment_metadata(deployment))
            )
          end

          def health(live: false)
            log.info { "checking health live=#{live} at #{api_base}" }
            baseline = health_baseline(live)
            return baseline.merge(checked: false) unless live

            response = connection.get(health_url)
            baseline.merge(checked: true, model_info: response.body)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'azure_foundry.health')
            baseline.merge(checked: true, ready: false, error: e.class.name, message: e.message)
          end

          def readiness(live: false)
            log.info { "checking readiness live=#{live} at #{api_base}" }
            health(live: live).merge(local: false, remote: true, endpoints: endpoint_manifest).tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models
            log.info { "listing configured deployment models from #{api_base}" }
            models = discover_offerings(live: false).map { |offering| model_info_from_offering(offering) }
            self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            models
          end

          def chat(
            messages:,
            model:,
            **options
          )
            log.info { "chat request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}), temperature: options[:temperature],
                               model: model_info(model, max_tokens: options[:max_tokens]),
                               params: options.fetch(:params, {}), tool_prefs: options[:tool_prefs])
          end

          def stream(
            messages:,
            model:,
            **options,
            &
          )
            log.info { "stream request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}), temperature: options[:temperature],
                               model: model_info(model, max_tokens: options[:max_tokens]),
                               params: options.fetch(:params, {}), tool_prefs: options[:tool_prefs], &)
          end

          def embed(
            text:,
            model:,
            **options
          )
            log.info { "embed request model=#{model}" }
            payload = Utils.deep_merge(
              render_embedding_payload(text, model: model_id(model), dimensions: options[:dimensions]),
              options.fetch(:params, {})
            )
            payload[:input_type] = options[:input_type] if options[:input_type]
            response = connection.post(embedding_url(model:), payload)
            parse_embedding_response(response, model: model_id(model), text:)
          end

          def count_tokens(
            messages:,
            model:,
            **_provider_options
          )
            {
              provider_family: :azure_foundry,
              model: model_id(model),
              supported: false,
              reason: 'Azure AI Foundry REST docs do not define a portable token-counting endpoint for this surface.',
              estimated_input_characters: messages.sum { |message| message.content.to_s.length }
            }
          end

          private

          def surface
            (config.azure_foundry_surface || MODEL_INFERENCE_SURFACE).to_sym
          end

          def health_baseline(live)
            {
              provider: :azure_foundry,
              configured: configured?,
              ready: configured?,
              live: live,
              api_base: api_base,
              surface: surface
            }
          end

          def model_info_from_offering(offering)
            capabilities = offering.capabilities.map(&:to_s)
            modalities = modalities_for_capabilities(capabilities)
            Legion::Extensions::Llm::Model::Info.new(
              id: offering.model,
              name: offering.metadata[:canonical_model_alias] || offering.model,
              provider: :azure_foundry,
              family: offering.metadata[:model_family],
              capabilities: capabilities,
              modalities_input: modalities[:input],
              modalities_output: modalities[:output],
              metadata: offering.to_h
            )
          end

          def api_version
            config.azure_foundry_api_version || DEFAULT_API_VERSION
          end

          def path_for(path)
            prefix = surface == MODEL_INFERENCE_SURFACE ? '/models' : ''
            suffix = surface == MODEL_INFERENCE_SURFACE ? "?api-version=#{api_version}" : ''
            "#{prefix}/#{path}#{suffix}"
          end

          def bearer_header
            token = config.azure_foundry_bearer_token
            token ? "Bearer #{token}" : nil
          end

          def configured_deployments
            self.class.normalize_deployments(config.azure_foundry_deployments)
          end

          def allowed_offerings
            configured_deployments.filter_map do |deployment|
              offering = offering_from_config(deployment)
              next unless offering

              mid = offering.respond_to?(:model) ? offering.model : (offering[:model] || deployment[:model])
              next unless model_allowed?(mid.to_s)

              offering
            end
          end

          def offering_from_config(deployment)
            deployment_name = value_for(deployment, :deployment) || value_for(deployment, :model)
            return nil if deployment_name.to_s.empty?

            offering_for(
              model: deployment_name,
              model_family: value_for(deployment, :model_family),
              canonical_model_alias: value_for(deployment, :canonical_model_alias),
              instance_id: value_for(deployment, :instance_id) || :default,
              usage_type: value_for(deployment, :usage_type),
              configured: true
            )
          end

          def build_offering(model:, model_family:, usage_type:, instance_id:, canonical_model_alias:, metadata:) # rubocop:disable Metrics/ParameterLists
            policy = resolve_capability_policy(model, usage_type)
            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :azure_foundry,
              instance_id: instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model,
              usage_type: usage_type.to_sym,
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              metadata: metadata.merge(
                model_family: model_family,
                canonical_model_alias: canonical_model_alias,
                requires_explicit_model_metadata: canonical_model_alias.nil? || model_family.nil?
              ).compact
            )
          end

          def with_live_metadata(offering)
            response = connection.get(models_url)
            metadata = offering.metadata.merge(model_info: response.body)
            with_health(offering, ready: true, checked: true, metadata:)
          end

          def with_health(offering, ready:, checked:, error: nil, metadata: offering.metadata)
            health = { ready: ready, checked: checked }
            health = health.merge(error: error.class.name, message: error.message) if error

            Legion::Extensions::Llm::Routing::ModelOffering.new(offering.to_h.merge(health:, metadata:))
          end

          def filter_offerings(offerings, model_family: nil, usage_type: nil, **)
            offerings.select do |offering|
              family_matches = model_family.nil? || offering.metadata[:model_family] == model_family.to_sym
              usage_matches = usage_type.nil? || offering.usage_type == usage_type.to_sym
              family_matches && usage_matches
            end
          end

          def deployment_metadata(deployment)
            return {} unless deployment

            deployment.to_h.transform_keys(&:to_sym).except(:deployment, :model_family, :usage_type)
          end

          def resolve_capability_policy(model, usage_type)
            if usage_type.to_sym == :embedding
              return { capabilities: %i[embeddings], sources: { embeddings: { value: true, source: :model_metadata } } }
            end

            real_caps = real_capabilities_for(model)
            provider_cfg = provider_level_config
            instance_cfg = instance_level_config
            model_cfg = model_config_for(model)

            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: real_caps,
              provider_catalog: {},
              probe: {},
              provider_envelope: { streaming: true },
              provider_config: provider_cfg,
              instance_config: instance_cfg,
              model_config: model_cfg
            )
          end

          def real_capabilities_for(model)
            caps = {}
            caps[:streaming] = true if Capabilities.streaming?(model)
            caps[:tools] = true if Capabilities.functions?(model)
            caps[:vision] = true if Capabilities.vision?(model)
            caps
          end

          def instance_level_config
            if config.respond_to?(:to_h)
              config.to_h
            elsif config.respond_to?(:instance_variable_get)
              data = config.instance_variable_get(:@data)
              data.is_a?(Hash) ? data : {}
            else
              {}
            end
          end

          def provider_level_config
            cfg = Legion::Extensions::Llm::CredentialSources.setting(:extensions, :llm, :azure_foundry)
            return {} unless cfg.is_a?(Hash)

            cfg.except(:instances, 'instances')
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'azure_foundry.provider_level_config')
            {}
          end

          def model_config_for(model)
            provider_cfg = provider_level_config
            models = provider_cfg[:models] || provider_cfg['models']
            return {} unless models.is_a?(Hash)

            model_id_str = Capabilities.model_id(model)
            models[model_id_str.to_sym] || models[model_id_str] || {}
          end

          def capabilities_for(model, usage_type)
            return %i[embedding] if usage_type.to_sym == :embedding

            Capabilities.critical_capabilities_for(model).map(&:to_sym)
          end

          def usage_type_for(model)
            Capabilities.embeddings?(model) ? :embedding : :inference
          end

          def normalize_family(value)
            value&.to_sym
          end

          def infer_model_family(model)
            id = model.to_s.downcase
            return :openai if id.match?(/gpt|o\d|text-embedding|dall-e/)
            return :mistral if id.include?('mistral')
            return :meta if id.match?(/llama|meta/)
            return :xai if id.match?(/grok|xai/)
            return :anthropic if id.include?('claude')
            return :microsoft if id.match?(/phi|microsoft/)

            nil
          end

          def value_for(hash, key)
            return nil unless hash.respond_to?(:key?)

            hash[key] || hash[key.to_s]
          end

          def model_id(model)
            self.class.resolve_model_id(model.respond_to?(:id) ? model.id : model, config:)
          end

          def model_info(model, max_tokens: nil)
            return model if model.respond_to?(:id) && max_tokens.nil?

            Legion::Extensions::Llm::Model::Info.new(id: model_id(model), provider: :azure_foundry,
                                                     max_output_tokens: max_tokens)
          end
        end
      end
    end
  end
end
