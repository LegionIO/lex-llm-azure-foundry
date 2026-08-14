# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Keys a live model catalog might report for context length. Defined here
        # (AzureFoundry namespace) so ProviderOfferingMetadata can resolve it
        # regardless of how it is included.
        CATALOG_CONTEXT_KEYS = %i[context_window max_input_tokens context_length].freeze

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
              azure_foundry_api_version azure_foundry_surface azure_foundry_deployments
            ]
          end

          def resolve_model_id(model_id, config: nil)
            deployment = deployment_config(model_id, config:)
            value_for(deployment, :deployment) || value_for(deployment, :model) || model_id.to_s
          end

          def deployment_config(model_id, config:)
            entries = normalize_deployments(config&.azure_foundry_deployments)
            entries.find do |entry|
              [value_for(entry, :deployment), value_for(entry, :model), value_for(entry, :canonical_model_alias)]
                .compact.map(&:to_s).include?(model_id.to_s)
            end
          end

          def normalize_deployments(deployments)
            return deployments.map { |n, m| m.to_h.merge(deployment: n) } if deployments.is_a?(Hash)

            Array(deployments).map { |d| d.is_a?(Hash) ? d.dup : { deployment: d.to_s } }
          end

          private

          def value_for(hash, key)
            return nil unless hash.respond_to?(:key?)

            hash[key] || hash[key.to_s]
          end
        end

        # Public dispatch methods — chat, stream, embed, count_tokens.
        module ProviderDispatchMethods
          def chat(messages:, model:, **options)
            log.info { "chat request model=#{model} messages=#{messages.size}" }
            complete(messages, tools: options.fetch(:tools, {}), temperature: options[:temperature],
                               model: model_info(model, max_tokens: options[:max_tokens]),
                               params: options.fetch(:params, {}), tool_prefs: options[:tool_prefs])
          end

          def stream(messages:, model:, **options, &)
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

          def count_tokens(messages:, model:, **_provider_options)
            {
              provider_family: :azure_foundry, model: model_id(model), supported: false,
              reason: 'Azure AI Foundry REST docs do not define a portable token-counting endpoint.',
              estimated_input_characters: messages.sum { |m| m.content.to_s.length }
            }
          end
        end

        # Private offering metadata, limits, and filter helpers — mixed into Provider.
        module ProviderOfferingMetadata
          private

          def with_live_metadata(offering)
            response = connection.get(models_url)
            metadata = offering.metadata.merge(model_info: response.body)
            limits = offering.to_h[:limits].to_h
            catalog_window = catalog_context_window(response.body)
            limits = limits.merge(context_window: catalog_window) if catalog_window
            with_health(offering, ready: true, checked: true, metadata: metadata, limits: limits)
          end

          def catalog_context_window(body)
            return nil unless body.is_a?(Hash)

            value = Legion::Extensions::Llm::AzureFoundry::CATALOG_CONTEXT_KEYS
                    .filter_map { |key| body[key] || body[key.to_s] }.first
            value&.to_i
          end

          def with_health(offering, **opts)
            ready = opts.fetch(:ready)
            checked = opts.fetch(:checked)
            error = opts[:error]
            metadata = opts.fetch(:metadata) { offering.metadata }
            limits = opts[:limits]
            health = { ready: ready, checked: checked }
            health = health.merge(error: error.class.name, message: error.message) if error
            data = offering.to_h.merge(health: health, metadata: metadata)
            data[:limits] = limits if limits
            Legion::Extensions::Llm::Routing::ModelOffering.new(data)
          end

          def filter_offerings(offerings, model_family: nil, usage_type: nil, **)
            offerings.select do |offering|
              family_matches = model_family.nil? || offering.metadata[:model_family] == model_family.to_sym
              usage_matches = usage_type.nil? || offering.usage_type == usage_type.to_sym
              family_matches && usage_matches
            end
          end

          def deployment_limits(deployment)
            return {} unless deployment

            context_window = value_for(deployment, :context_window) || value_for(deployment, :max_input_tokens)
            { context_window: context_window&.to_i,
              max_output_tokens: value_for(deployment, :max_output_tokens)&.to_i }.compact
          end

          def deployment_metadata(deployment)
            return {} unless deployment

            deployment.to_h.transform_keys(&:to_sym).except(:deployment, :model_family, :usage_type)
          end
        end

        # Private offering-building and discovery helpers — mixed into Provider.
        module ProviderOfferingHelpers
          include ProviderOfferingMetadata

          private

          def discover_offerings(live: false, raise_on_unreachable: false, **filters)
            offerings = allowed_offerings
            return filter_offerings(offerings, **filters) unless live

            resolved = offerings.map { |offering| with_live_metadata(offering) }
            filter_offerings(resolved, **filters)
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            log.warn("[#{slug}] instance=#{provider_instance_id} unreachable: #{e.message}")
            raise if raise_on_unreachable

            []
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
            offering_for(
              model: value_for(deployment, :deployment) || value_for(deployment, :model),
              model_family: value_for(deployment, :model_family),
              canonical_model_alias: value_for(deployment, :canonical_model_alias),
              instance_id: provider_instance_id,
              usage_type: value_for(deployment, :usage_type) || :inference,
              metadata: deployment_metadata(deployment)
            )
          end

          def offering_from_model(model_info, _health: nil)
            offering_for(**extract_model_info_attrs(model_info), instance_id: provider_instance_id)
          end

          def extract_model_info_attrs(model_info)
            { model: model_attr(model_info, :id, 'id'),
              model_family: model_attr(model_info, :family, 'model_family'),
              canonical_model_alias: extract_model_name(model_info),
              usage_type: (model_info.respond_to?(:embedding?) && model_info.embedding? ? :embedding : :inference),
              metadata: (if model_info.respond_to?(:metadata)
                           model_info.metadata
                         else
                           {}.tap do |h|
                             h.merge!(model_info) if model_info.is_a?(Hash)
                           end
                         end) }
          end

          def model_attr(model_info, sym_key, str_key)
            model_info.respond_to?(sym_key) ? model_info.public_send(sym_key) : model_info[str_key]
          end

          def extract_model_name(model_info)
            return model_info.name if model_info.respond_to?(:name)

            model_info['name'] || model_attr(model_info, :id, 'id')
          end

          def offering_for(model:, **opts)
            build_offering(**resolve_offering_attributes(model: model, opts: opts))
          end

          def resolve_offering_attributes(model:, opts:)
            deployment = self.class.deployment_config(model, config:)
            model_id = self.class.resolve_model_id(model, config:)
            { model: model_id, instance_id: opts[:instance_id] || provider_instance_id,
              model_family: resolve_model_family(opts, deployment, model_id),
              canonical_model_alias: opts[:canonical_model_alias] || value_for(deployment, :canonical_model_alias),
              usage_type: resolve_usage_type(opts, deployment, model_id),
              metadata: opts.except(:model_family, :canonical_model_alias, :instance_id, :usage_type)
                            .merge(deployment_metadata(deployment)),
              limits: deployment_limits(deployment) }
          end

          def resolve_usage_type(opts, deployment, model_id)
            opts[:usage_type] || value_for(deployment, :usage_type) || usage_type_for(model_id)
          end

          def resolve_model_family(opts, deployment, model_id)
            normalize_family(opts[:model_family] || value_for(deployment, :model_family) ||
                             infer_model_family(model_id))
          end

          def build_offering(model:, **opts)
            usage_type = opts.fetch(:usage_type, :inference)
            policy = resolve_capability_policy(model, usage_type)
            build_offering_record(model: model, usage_type: usage_type, policy: policy, opts: opts)
          end

          def build_offering_record(model:, usage_type:, policy:, opts:)
            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :azure_foundry, instance_id: opts[:instance_id],
              transport: offering_transport, tier: offering_tier,
              model: model, usage_type: usage_type.to_sym,
              capabilities: policy[:capabilities], capability_sources: policy[:sources],
              limits: opts.fetch(:limits, {}), metadata: build_offering_metadata(opts)
            )
          end

          def build_offering_metadata(opts)
            opts.fetch(:metadata, {}).merge(
              model_family: opts[:model_family], canonical_model_alias: opts[:canonical_model_alias],
              requires_explicit_model_metadata: opts[:canonical_model_alias].nil? || opts[:model_family].nil?
            ).compact
          end
        end

        # Private capability resolution helpers — mixed into Provider.
        module ProviderCapabilityHelpers
          private

          def resolve_capability_policy(model, usage_type)
            if usage_type.to_sym == :embedding
              return { capabilities: %i[embedding],
                       sources: { embedding: { value: true, source: :model_metadata } } }
            end

            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: real_capabilities_for(model), provider_catalog: {}, probe: {},
              provider_envelope: { streaming: true }, provider_config: provider_level_config,
              instance_config: instance_level_config, model_config: model_config_for(model)
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
            handle_exception(e, level: :warn, handled: true, operation: 'azure_foundry.provider_level_config')
            {}
          end

          def model_config_for(model)
            models = provider_level_config.then { |cfg| cfg[:models] || cfg['models'] }
            return {} unless models.is_a?(Hash)

            model_id_str = Capabilities.model_id(model)
            models[model_id_str.to_sym] || models[model_id_str] || {}
          end

          def usage_type_for(model) = Capabilities.embeddings?(model) ? :embedding : :inference

          def normalize_family(value) = value&.to_sym

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
        end

        # Azure AI Foundry and Azure OpenAI hosted provider surface.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          extend ProviderClassMethods
          include ProviderOfferingHelpers
          include ProviderCapabilityHelpers
          include ProviderDispatchMethods

          DEFAULT_API_VERSION = '2024-05-01-preview'
          MODEL_INFERENCE_SURFACE = :model_inference
          OPENAI_V1_SURFACE = :openai_v1

          private_class_method :value_for
          public :discover_offerings, :offering_for

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

          def list_models
            log.info { "listing configured deployment models from #{api_base}" }
            discover_offerings(live: false).map { |offering| model_info_from_offering(offering) }
          end

          private

          def surface = (config.azure_foundry_surface || MODEL_INFERENCE_SURFACE).to_sym

          def health_baseline(live)
            ready = configured?
            { provider: :azure_foundry, instance_id: provider_instance_id, configured: ready,
              ready: ready, live: live, status: ready ? 'healthy' : 'unhealthy',
              api_base: api_base, surface: surface }
          end

          def model_info_from_offering(offering)
            capabilities = offering.capabilities.map(&:to_s)
            modalities = modalities_for_capabilities(capabilities)
            Legion::Extensions::Llm::Model::Info.new(
              id: offering.model, name: offering.metadata[:canonical_model_alias] || offering.model,
              provider: :azure_foundry, family: offering.metadata[:model_family],
              capabilities: capabilities, context_length: offering.context_window,
              modalities_input: modalities[:input], modalities_output: modalities[:output],
              metadata: offering.to_h
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
