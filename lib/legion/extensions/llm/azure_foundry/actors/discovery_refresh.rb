# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Actor
          # SSOT v3 periodic discovery actor for Azure AI Foundry provider instances.
          # Claims instances, discovers deployments from config, probes health
          # via models/info, and publishes complete OfferingDraft snapshots through
          # the Inventory::Publisher. Supports coalesced reactive probes after
          # dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Metrics/ClassLength
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              settings[:discovery_interval] || self.class.every_seconds
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discovery_refresh.shutdown')
            end

            private

            # -- Publisher -------------------------------------------------------

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
            end

            # -- Initial discovery -----------------------------------------------

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:) # rubocop:disable Metrics/AbcSize
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :azure_foundry, instance_id: instance_id
              )

              callable = AzureFoundryCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )

              publisher_token = publisher.claim_instance(
                instance_id: instance_id,
                callable: callable,
                probe_request_handle: probe_coordinator
              )

              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: publisher_token
              )

              readiness = check_health(instance_cfg: instance_cfg)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: publisher_token,
                  offerings: offerings,
                  sequence: 0,
                  probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end

              @instance_states[instance_id] = {
                name: name,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: callable,
                probe_coordinator: probe_coordinator,
                publisher_token: publisher_token,
                sequence: 0,
                offerings: offerings
              }
            end

            # -- Tick refresh ----------------------------------------------------

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token],
                  offerings: new_offerings,
                  sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end

            # -- Readiness probing -----------------------------------------------

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              coordinator&.finish_probe rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              coordinator&.finish_probe(request: request) rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.probe_enqueue',
                                    instance_id: instance_id)
                false
              end
            end

            # -- Health check ----------------------------------------------------

            def check_health(instance_cfg:)
              endpoint = instance_cfg[:azure_foundry_endpoint] || instance_cfg[:endpoint]
              conn = build_health_connection(endpoint: endpoint, instance_cfg: instance_cfg)
              url = health_path(instance_cfg: instance_cfg)
              response = conn.get(url)
              build_readiness_from_response(response: response, endpoint: endpoint)
            rescue Faraday::ConnectionFailed => e
              readiness_failure(reason: "Azure Foundry health connection failed: #{e.message}", error: e)
            rescue StandardError => e
              readiness_failure(reason: "Azure Foundry health error: #{e.message}", error: e)
            end

            def health_path(instance_cfg:)
              surface = resolve_surface(instance_cfg: instance_cfg)
              return 'models' if surface == :openai_v1

              version = resolve_api_version(instance_cfg: instance_cfg)
              "models/info?api-version=#{version}"
            end

            def resolve_surface(instance_cfg:)
              (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] || :model_inference).to_sym
            end

            def resolve_api_version(instance_cfg:)
              instance_cfg[:azure_foundry_api_version] || instance_cfg[:api_version] || '2024-05-01-preview'
            end

            def build_readiness_from_response(response:, endpoint:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Azure Foundry health returned #{response.status}",
                metadata: { status: response.status, endpoint: endpoint.to_s }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false,
                reason: reason,
                metadata: { error_class: error.class.name }
              )
            end

            # -- Offering discovery -----------------------------------------------

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              deployments = configured_deployments(instance_cfg: instance_cfg)

              deployments.filter_map do |deployment|
                deployment_name = deployment[:deployment] || deployment[:model]
                next if deployment_name.nil? || deployment_name.to_s.strip.empty?

                build_offering_draft(
                  deployment: deployment,
                  deployment_name: deployment_name.to_s,
                  instance_cfg: instance_cfg,
                  instance_key: instance_key
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discover_offerings')
              []
            end

            def configured_deployments(instance_cfg:)
              raw = instance_cfg[:azure_foundry_deployments] || instance_cfg[:deployments] || []
              return deployments_from_hash(raw) if raw.is_a?(Hash)

              Array(raw).map { |entry| normalize_deployment_entry(entry: entry) }
            end

            def deployments_from_hash(hash)
              hash.map do |name, metadata|
                entry = metadata.is_a?(Hash) ? metadata.dup : {}
                entry[:deployment] ||= name.to_s
                entry.transform_keys(&:to_sym)
              end
            end

            def normalize_deployment_entry(entry:)
              return entry.transform_keys(&:to_sym) if entry.is_a?(Hash)

              { deployment: entry.to_s }
            end

            def build_offering_draft(deployment:, deployment_name:, instance_cfg:, instance_key:)
              tier = (instance_cfg[:tier] || :cloud).to_sym
              model_id = (deployment[:model] || deployment_name).to_s
              embed_supported = embedding_deployment?(deployment: deployment, deployment_name: deployment_name)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: deployment_name,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_supported),
                capability_evidence: build_capability_evidence(
                  deployment: deployment, deployment_name: deployment_name, embed_supported: embed_supported
                ),
                context_evidence: build_context_evidence(deployment: deployment, instance_cfg: instance_cfg),
                max_output_evidence: build_max_output_evidence(deployment: deployment, instance_cfg: instance_cfg),
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(deployment_name: deployment_name),
                metadata: build_offering_metadata(
                  deployment: deployment, deployment_name: deployment_name, instance_key: instance_key
                ),
                publication_source: :provider_static_catalog
              )
            end

            # -- Operation evidence -----------------------------------------------

            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              embed_status = embed_supported ? :supported : :unsupported

              {
                chat: op_evidence(operation: :chat, status: :supported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: :supported, observed_at: now),
                embed: op_evidence(operation: :embed, status: embed_status, observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unsupported, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation,
                status: status,
                source: source,
                observed_at: observed_at
              )
            end

            # -- Capability evidence -----------------------------------------------

            def build_capability_evidence(deployment:, deployment_name:, embed_supported:)
              evidence = {
                completion: cap_evidence(
                  capability: :completion, status: :supported, source: :provider_implementation
                ),
                streaming: cap_evidence(
                  capability: :streaming, status: :supported, source: :provider_implementation
                )
              }

              unless embed_supported
                evidence[:tools] = cap_evidence(
                  capability: :tools, status: :supported, source: :provider_implementation
                )
              end

              unless embed_supported
                has_vision = vision_supported?(deployment_name: deployment_name)
                evidence[:vision] = cap_evidence(
                  capability: :vision,
                  status: has_vision ? :supported : :unknown,
                  source: has_vision ? :provider_implementation : :default_false
                )
              end

              if embed_supported
                evidence[:embedding] = cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              end

              evidence[:thinking] = cap_evidence(
                capability: :thinking,
                status: :unknown,
                source: deployment.key?(:enable_thinking) ? :instance_override : :default_false
              )

              evidence
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability,
                status: status,
                source: source,
                observed_at: Time.now.freeze
              )
            end

            def vision_supported?(deployment_name:)
              deployment_name.to_s.match?(/(gpt-4|gpt-5|llava|vision|phi-3.5)/i)
            end

            # -- Value evidence builders -------------------------------------------

            def build_context_evidence(deployment:, instance_cfg:)
              ctx = deployment[:context_window] || deployment[:max_input_tokens] ||
                    instance_cfg[:context_window] || instance_cfg[:max_input_tokens]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_max_output_evidence(deployment:, instance_cfg:)
              max_out = deployment[:max_output_tokens] || instance_cfg[:max_output_tokens]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: max_out, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :unknown, source: :absent
              )
            end

            # -- Embedding detection -----------------------------------------------

            def embedding_deployment?(deployment:, deployment_name:)
              usage = (deployment[:usage_type] || deployment[:type]).to_s.downcase
              return true if %w[embed embedding].include?(usage)

              deployment_name.to_s.match?(/embed/i)
            end

            # -- Quota domains -----------------------------------------------------

            def build_quota_domains(deployment_name:)
              return {} if deployment_name.nil? || deployment_name.to_s.strip.empty?

              {
                chat: "azure:deployment:#{deployment_name}",
                stream_chat: "azure:deployment:#{deployment_name}",
                embed: "azure:deployment:#{deployment_name}"
              }
            end

            # -- Offering metadata -------------------------------------------------

            def build_offering_metadata(deployment:, deployment_name:, instance_key:)
              meta = { raw_deployment: deployment_name }
              meta[:model_family] = deployment[:model_family].to_sym if deployment[:model_family]
              if deployment[:canonical_model_alias]
                meta[:canonical_model_alias] =
                  deployment[:canonical_model_alias].to_s
              end
              meta[:instance_id] = instance_key.instance_id
              meta
            end

            # -- Instance ID derivation --------------------------------------------

            def derive_instance_id(instance_cfg:)
              endpoint = instance_cfg[:azure_foundry_endpoint] || instance_cfg[:endpoint] || 'https://localhost:443'
              host_port = extract_host_port(url: endpoint)
              api_key = instance_cfg[:azure_foundry_api_key] || instance_cfg.dig(:credentials, :api_key)

              if api_key.is_a?(String) && !api_key.strip.empty?
                fingerprint = ::Digest::SHA256.hexdigest(api_key)[0, 6]
                "#{host_port}/ak:#{fingerprint}"
              else
                host_port
              end
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = (uri.host || 'localhost').downcase
              port = uri.port
              "#{host}:#{port}"
            rescue URI::InvalidURIError
              'unknown:0'
            end

            # -- Graceful shutdown -------------------------------------------------

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end

            # -- Configuration -----------------------------------------------------

            def configured_instances
              instances = instances_from_settings
              return instances unless instances.empty?

              build_default_instance
            end

            def instances_from_settings
              instances = {}
              cfg_instances = settings[:instances]
              return instances unless cfg_instances.is_a?(Hash)

              cfg_instances.each do |name, config|
                instances[name.to_sym] = normalize_instance_config(config: config)
              end
              instances
            end

            def build_default_instance
              endpoint = settings[:endpoint] || settings[:azure_foundry_endpoint]
              return {} if endpoint.nil? || endpoint.to_s.strip.empty?

              { default: default_instance_config(endpoint: endpoint) }
            end

            def default_instance_config(endpoint:)
              {
                azure_foundry_endpoint: endpoint,
                tier: settings[:tier] || :cloud,
                azure_foundry_api_key: default_api_key,
                azure_foundry_surface: default_surface,
                azure_foundry_api_version: default_api_version_setting,
                azure_foundry_deployments: default_deployments
              }
            end

            def default_api_key
              settings.dig(:credentials, :api_key) || settings[:azure_foundry_api_key]
            end

            def default_surface
              settings.dig(:provider, :surface) || settings[:azure_foundry_surface]
            end

            def default_api_version_setting
              settings.dig(:provider, :api_version) || settings[:azure_foundry_api_version]
            end

            def default_deployments
              settings.dig(:provider, :deployments) || settings[:azure_foundry_deployments] || []
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              resolve_azure_endpoint(normalized: normalized)
              resolve_azure_credentials(normalized: normalized)
              resolve_azure_provider_settings(normalized: normalized)
              normalized[:tier] ||= :cloud
              normalized
            end

            def resolve_azure_endpoint(normalized:)
              normalized[:azure_foundry_endpoint] ||= normalized.delete(:endpoint)
              normalized[:azure_foundry_endpoint] ||= normalized.delete(:base_url)
              normalized[:azure_foundry_endpoint] ||= normalized.delete(:api_base)
            end

            def resolve_azure_credentials(normalized:)
              creds = normalized.delete(:credentials)
              if creds.is_a?(Hash)
                creds = creds.transform_keys(&:to_sym)
                normalized[:azure_foundry_api_key] ||= creds[:api_key]
              end
              normalized[:azure_foundry_api_key] ||= normalized.delete(:api_key)
            end

            def resolve_azure_provider_settings(normalized:)
              apply_nested_provider(normalized: normalized)
              normalized[:azure_foundry_surface] ||= normalized.delete(:surface)
              normalized[:azure_foundry_api_version] ||= normalized.delete(:api_version)
              normalized[:azure_foundry_deployments] ||= normalized.delete(:deployments)
            end

            def apply_nested_provider(normalized:)
              prov = normalized.delete(:provider)
              return unless prov.is_a?(Hash)

              prov = prov.transform_keys(&:to_sym)
              normalized[:azure_foundry_surface] ||= prov[:surface]
              normalized[:azure_foundry_api_version] ||= prov[:api_version]
              normalized[:azure_foundry_deployments] ||= prov[:deployments]
            end

            # -- HTTP connections ---------------------------------------------------

            def build_health_connection(endpoint:, instance_cfg:)
              require 'faraday'
              base = normalize_endpoint_for_connection(endpoint: endpoint, instance_cfg: instance_cfg)
              Faraday.new(url: base) do |f|
                f.options.timeout = 10
                f.options.open_timeout = 5
                apply_auth_headers(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def normalize_endpoint_for_connection(endpoint:, instance_cfg:)
              url = (endpoint || 'https://localhost').to_s.sub(%r{/*\z}, '')
              surface = (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] || :model_inference).to_sym
              return "#{url}/openai/v1" if surface == :openai_v1 && !url.end_with?('/openai/v1')

              url
            end

            def apply_auth_headers(faraday:, instance_cfg:)
              api_key = instance_cfg[:azure_foundry_api_key] || instance_cfg.dig(:credentials, :api_key)
              faraday.headers['api-key'] = api_key if api_key.is_a?(String) && !api_key.strip.empty?
            end
          end

          # Callable wrapper for an Azure Foundry provider instance. Implements the
          # `disconnect`, `disconnected?`, and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          # Also implements dispatch operations: chat, stream_chat, embed, count_tokens.
          class AzureFoundryCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[azure_foundry][callable] disconnected' }
            end

            def chat(messages:, model:, **)
              provider_instance.chat(messages: messages, model: model, **)
            end

            def stream_chat(messages:, model:, **)
              provider_instance.stream(messages: messages, model: model, **)
            end

            def embed(text:, model:, **)
              provider_instance.embed(text: text, model: model, **)
            end

            def count_tokens(messages:, model:, **)
              provider_instance.count_tokens(messages: messages, model: model, **)
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]

              kind = case error
                     when Faraday::ConnectionFailed
                       :connection_failure
                     when Faraday::TimeoutError
                       :timeout
                     when Faraday::ClientError
                       classify_client_error(error: error)
                     when Faraday::ServerError
                       classify_server_error(error: error)
                     when Legion::Extensions::Llm::OverloadedError
                       :overloaded
                     else
                       :provider_error
                     end

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def provider_instance
              @provider_instance ||= Legion::Extensions::Llm::AzureFoundry::Provider.new(@instance_cfg)
            end

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/529/5xx as instance_unavailable by status alone.
              # Only an explicit Azure flat "service unavailable" response body signal
              # (which Azure rarely produces distinctly) would justify
              # instance_unavailable. Everything else is request-local.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503, 529 then :overloaded
              else :provider_error
              end
            end
          end
        end
      end
    end
  end
end
