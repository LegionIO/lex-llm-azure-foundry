# frozen_string_literal: true

require 'uri'
require 'time'
require 'concurrent'
require 'faraday'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/inventory/weight_reconciler'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  Legion::Logging.warn("[azure_foundry] LegionIO actor runtime unavailable: #{e.message}")
end

unless defined?(Legion::Extensions::Actors::Every)
  raise LoadError, 'LegionIO actor runtime is required for the Azure Foundry discovery actor'
end

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Actor
          # Health-check helpers — non-billable readiness operations only.
          # Readiness is a non-inference GET of the model catalog
          # (models/info or /openai/v1/models), never a chat/embed call.
          module HealthCheckHelpers
            private

            def check_health(instance_cfg:)
              endpoint = instance_cfg[:azure_foundry_endpoint]
              conn = build_health_connection(endpoint: endpoint, instance_cfg: instance_cfg)
              response = conn.get(health_path(instance_cfg: instance_cfg))
              build_readiness_from_response(response: response, endpoint: endpoint)
            rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.check_health')
              readiness_failure(reason: "Azure Foundry health network error: #{e.message}", error: e)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.check_health')
              readiness_failure(reason: "Azure Foundry health error: #{e.message}", error: e)
            end

            def health_path(instance_cfg:)
              surface = (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] || :model_inference).to_sym
              return 'models' if surface == :openai_v1

              version = instance_cfg[:azure_foundry_api_version] || instance_cfg[:api_version] || '2024-05-01-preview'
              "models/info?api-version=#{version}"
            end

            def build_readiness_from_response(response:, endpoint:)
              status = http_status(response)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: status == 200,
                reason: "Azure Foundry health returned #{status}",
                metadata: { status: status, endpoint: endpoint.to_s }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: reason, metadata: { error_class: error.class.name }
              )
            end

            def build_health_connection(endpoint:, instance_cfg:)
              base = normalize_endpoint_for_connection(endpoint: endpoint, instance_cfg: instance_cfg)
              Faraday.new(url: base) do |f|
                f.options.timeout = 10
                f.options.open_timeout = 5
                apply_auth_headers(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def normalize_endpoint_for_connection(endpoint:, instance_cfg:)
              url = endpoint.to_s.sub(%r{/*\z}, '')
              raise ArgumentError, 'azure_foundry_endpoint is required for the health connection' if url.strip.empty?

              surface = (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] || :model_inference).to_sym
              return "#{url}/openai/v1" if surface == :openai_v1 && !url.end_with?('/openai/v1')

              url
            end

            def apply_auth_headers(faraday:, instance_cfg:)
              api_key = instance_cfg[:azure_foundry_api_key]
              faraday.headers['api-key'] = api_key if api_key.is_a?(String) && !api_key.strip.empty?
            end

            # Accepts the real Faraday shapes (Faraday::Response from conn.get,
            # Faraday::Env on error paths) as well as a plain Hash.
            def http_status(response)
              return response[:status] if response.is_a?(Hash)

              response.status
            end
          end

          # Capability and operation evidence builders — the immutable facts an
          # OfferingDraft carries about what a deployment can and cannot do.
          module CapabilityEvidenceHelpers
            private

            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              # An embedding deployment is authoritative evidence that chat is
              # NOT servable on it (matches bedrock's exclusion): publishing
              # chat :supported would let a plain chat request misroute to an
              # embedding-only deployment.
              chat_status = embed_supported ? :unsupported : :supported
              embed_status = embed_supported ? :supported : :unsupported
              {
                chat: op_evidence(operation: :chat, status: chat_status, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: chat_status, observed_at: now),
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
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(deployment:, embed_supported:)
              evidence = base_capability_evidence
              unless embed_supported
                evidence[:tools] = cap_evidence(
                  capability: :tools, status: :supported, source: :provider_implementation
                )
                # Vision capability: model-name regex is not authoritative proof — stays :unknown.
                evidence[:vision] = cap_evidence(capability: :vision, status: :unknown, source: :default_false)
              end
              if embed_supported
                evidence[:embedding] = cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              end
              evidence[:thinking] = cap_evidence(
                capability: :thinking, status: :unknown,
                source: deployment.key?(:enable_thinking) ? :instance_override : :default_false
              )
              evidence
            end

            def base_capability_evidence
              {
                completion: cap_evidence(
                  capability: :completion, status: :supported, source: :provider_implementation
                ),
                streaming: cap_evidence(
                  capability: :streaming, status: :supported, source: :provider_implementation
                )
              }
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end

          # Deployment configuration parsing helpers — normalizes the many shapes
          # operators use when specifying deployments in instance config.
          module DeploymentParserHelpers
            private

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

            def embedding_deployment?(deployment:, deployment_name:)
              usage = (deployment[:usage_type] || deployment[:type]).to_s.downcase
              return true if %w[embed embedding].include?(usage)

              deployment_name.to_s.match?(/embed/i)
            end
          end

          # Offering draft builders — assembles complete OfferingDrafts for each
          # deployment of an instance.
          module OfferingBuilderHelpers
            include CapabilityEvidenceHelpers
            include DeploymentParserHelpers

            private

            # D16: programming errors (NameError/NoMethodError/ArgumentError) are
            # bugs in the builder, not "no offerings" — they must fail loud. Only
            # runtime errors may degrade to an empty set.
            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              build_offering_set(instance_cfg: instance_cfg, instance_key: instance_key)
            rescue StandardError => e
              raise e if programming_error?(e)

              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discover_offerings')
              []
            end

            def programming_error?(error)
              error.is_a?(NameError) || error.is_a?(NoMethodError) || error.is_a?(ArgumentError)
            end

            def build_offering_set(instance_cfg:, instance_key:)
              configured_deployments(instance_cfg: instance_cfg).filter_map do |deployment|
                deployment_name = deployment[:deployment] || deployment[:model]
                next if deployment_name.nil? || deployment_name.to_s.strip.empty?

                build_offering_draft(deployment: deployment, deployment_name: deployment_name.to_s,
                                     instance_cfg: instance_cfg, instance_key: instance_key)
              end
            end

            def build_offering_draft(deployment:, deployment_name:, instance_cfg:, instance_key:)
              tier = (instance_cfg[:tier] || :cloud).to_sym
              model_id = (deployment[:model] || deployment_name).to_s
              embed = embedding_deployment?(deployment: deployment, deployment_name: deployment_name)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: deployment_name, model: model_id, tier: tier,
                **offering_evidence_fields(deployment: deployment, instance_cfg: instance_cfg, embed: embed),
                quota_domains: build_quota_domains(deployment_name: deployment_name),
                metadata: build_offering_metadata(deployment: deployment, deployment_name: deployment_name,
                                                  instance_key: instance_key).freeze,
                publication_source: :provider_static_catalog,
                **weight_fields(instance_key: instance_key, deployment_name: deployment_name,
                                model_id: model_id, tier: tier)
              )
            end

            def weight_fields(instance_key:, deployment_name:, model_id:, tier:)
              inputs = Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
                settings: Legion::Settings, instance_key: instance_key,
                provider_native_key: deployment_name, model: model_id, tier: tier
              )
              { weight_inputs: inputs, base_weight: Legion::Extensions::Llm::Inventory::WeightSchema.base_weight(inputs) }
            end

            def offering_evidence_fields(deployment:, instance_cfg:, embed:)
              {
                operation_evidence: build_operation_evidence(embed_supported: embed),
                capability_evidence: build_capability_evidence(deployment: deployment, embed_supported: embed),
                context_evidence: build_context_evidence(deployment: deployment, instance_cfg: instance_cfg),
                max_output_evidence: build_max_output_evidence(deployment: deployment, instance_cfg: instance_cfg),
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence
              }
            end

            def build_context_evidence(deployment:, instance_cfg:)
              ctx = deployment[:context_window] || deployment[:max_input_tokens] ||
                    instance_cfg[:context_window] || instance_cfg[:max_input_tokens]
              return absent_value_evidence unless ctx.is_a?(Integer) && ctx.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known, value: ctx, source: :provider_catalog
              )
            end

            def build_max_output_evidence(deployment:, instance_cfg:)
              max_out = deployment[:max_output_tokens] || instance_cfg[:max_output_tokens]
              return absent_value_evidence unless max_out.is_a?(Integer) && max_out.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known, value: max_out, source: :provider_catalog
              )
            end

            def build_quota_domains(deployment_name:)
              return {} if deployment_name.nil? || deployment_name.to_s.strip.empty?

              {
                chat: "azure:deployment:#{deployment_name}",
                stream_chat: "azure:deployment:#{deployment_name}",
                embed: "azure:deployment:#{deployment_name}"
              }
            end

            def build_offering_metadata(deployment:, deployment_name:, instance_key:)
              meta = { raw_deployment: deployment_name }
              meta[:model_family] = deployment[:model_family].to_sym if deployment[:model_family]
              meta[:canonical_model_alias] = deployment[:canonical_model_alias].to_s if
                deployment[:canonical_model_alias]
              meta[:instance_id] = instance_key.instance_id
              meta[:physical_id] = instance_key.physical_id if instance_key.physical_id
              meta
            end
          end

          # Complete OfferingDraft comparison. Evidence observation timestamps
          # are telemetry-only; every other draft and evidence field remains
          # authoritative. Catalog order is set-like and duplicate counts remain
          # significant.
          module OfferingComparisonHelpers
            SCALAR_EVIDENCE_FIELDS = %i[
              context_evidence max_output_evidence embedding_dimensions_evidence
              model_revision_evidence tokenizer_evidence
            ].freeze

            private

            def offerings_changed?(previous:, current:)
              offerings_contract(previous) != offerings_contract(current)
            end

            def offerings_contract(offerings)
              contracts = offerings.map { |draft| stable_offering_contract(draft) }
              grouped = contracts.group_by do |contract|
                [contract.fetch(:provider_native_key), contract.fetch(:model)]
              end
              grouped.sort_by { |identity, _| identity.map { |value| value.to_s.b } }
                     .to_h.transform_values(&:tally)
            end

            def stable_offering_contract(draft)
              contract = draft.to_h
              contract[:operation_evidence] = stable_evidence_map(contract.fetch(:operation_evidence))
              contract[:capability_evidence] = stable_evidence_map(contract.fetch(:capability_evidence))
              SCALAR_EVIDENCE_FIELDS.each do |field|
                contract[field] = stable_evidence(contract.fetch(field))
              end
              contract
            end

            def stable_evidence_map(evidence_by_key)
              evidence_by_key.transform_values { |evidence| stable_evidence(evidence) }
            end

            def stable_evidence(evidence)
              evidence.to_h.except(:observed_at)
            end
          end

          # Configuration helpers. The single source of configured instances is
          # the module-level AzureFoundry.discover_instances (the same reader the
          # fleet responder uses); the actor only filters to claimable entries.
          module InstanceConfigHelpers
            private

            # Claimable instances: enabled, with a non-blank endpoint (already
            # enforced by discover_instances) and at least one credential. The
            # synthetic instances.default placeholder (endpoint: nil) and
            # credential-less entries are skipped, never claimed.
            def configured_instances
              Legion::Extensions::Llm::AzureFoundry.discover_instances.filter do |name, instance_cfg|
                claimable_instance?(name: name, instance_cfg: instance_cfg)
              end
            end

            def claimable_instance?(name:, instance_cfg:)
              if instance_cfg[:enabled] == false
                log.warn("[azure_foundry] skipping instance #{name}: disabled")
                return false
              end
              return true if instance_credential?(instance_cfg)

              log.warn("[azure_foundry] skipping instance #{name}: no API credential configured")
              false
            end

            def instance_credential?(instance_cfg)
              credential_string?(instance_cfg[:azure_foundry_api_key]) ||
                credential_string?(instance_cfg[:azure_foundry_bearer_token])
            end

            def credential_string?(value)
              value.is_a?(String) && !value.strip.empty?
            end
          end

          # Physical-ID derivation from endpoint + credential fingerprint. The
          # derived physical id identifies the exact endpoint + credential that
          # can independently become unavailable — it is the SECONDARY
          # InstanceKey field (dedup/diagnostics only), never the identity.
          # The instance_id is the operator's config NAME (the key the router
          # resolves instances.<name> settings by).
          module InstanceIdentityHelpers
            private

            def derive_physical_id(instance_cfg:)
              endpoint = instance_cfg[:azure_foundry_endpoint]
              raise ArgumentError, 'azure_foundry_endpoint is required to derive the physical id' unless
                credential_string?(endpoint)

              host_port = extract_host_port(url: endpoint)
              api_key = instance_cfg[:azure_foundry_api_key]
              return host_port unless credential_string?(api_key)

              "#{host_port}/ak:#{Legion::Extensions::Llm::CredentialSources.credential_fingerprint(api_key)}"
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = (uri.host || 'localhost').downcase
              "#{host}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.extract_host_port',
                                  url: url.to_s)
              raise
            end
          end

          # Readiness probe lifecycle helpers — coalesced token-bound probes.
          module ProbeHelpers
            private

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                physical_id: state[:instance_key].physical_id
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              report_probe_result(
                instance_id: instance_id, probe_token: probe_token, readiness: readiness, state: state
              )
            rescue StandardError => e
              finish_probe_safely(coordinator: coordinator)
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = tracked_instance_state(instance_id)
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                physical_id: state[:instance_key].physical_id
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              report_probe_result(
                instance_id: instance_id, probe_token: probe_token, readiness: readiness, state: state
              )
            rescue StandardError => e
              finish_probe_safely(coordinator: coordinator, request: request)
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def tracked_instance_state(instance_id)
              return unless @instance_states

              state_mutex.synchronize { @instance_states[instance_id] }
            end

            def finish_probe_safely(coordinator:, request: nil)
              args = request ? { request: request } : {}
              coordinator&.finish_probe(**args)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.finish_probe_cleanup')
            end

            def report_probe_result(instance_id:, probe_token:, readiness:, state:)
              physical_id = state[:instance_key].physical_id
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token,
                                              physical_id: physical_id)
                state[:last_probe_outcome] = :success
                write_instance_health(
                  config_name: state[:name], available: true, reason: 'readiness probe succeeded',
                  probe_outcome: :success, source: :readiness_probe
                )
              else
                publisher.readiness_failed(instance_id: instance_id, probe_token: probe_token,
                                           reason: readiness.reason, physical_id: physical_id)
                state[:last_probe_outcome] = :failure
                write_instance_health(
                  config_name: state[:name], available: false, reason: readiness.reason,
                  probe_outcome: :failure, source: :readiness_probe
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
          end

          # Graceful shutdown — removes all claimed instances on actor stop.
          module ShutdownHelpers
            private

            def remove_all_instances
              return unless @instance_states

              drain_instance_states.each do |instance_id, state|
                remove_published_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.remove_instance',
                                    instance_id: instance_id)
              end
            end

            def drain_instance_states
              state_mutex.synchronize do
                tracked = @instance_states.each_pair.map { |instance_id, state| [instance_id, state] }
                @instance_states.clear
                dormant_weight_tracker.clear!
                tracked
              end
            end

            def remove_published_instance(instance_id:, state:)
              publisher.remove_instance(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                physical_id: state[:instance_key].physical_id
              )
              clear_instance_health(config_name: state[:name])
            end
          end

          # Per-instance activation helpers — claim, state tracking, removal.
          module ActivationHelpers
            private

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(
                provider_family: :azure_foundry,
                compatibility_adapter: Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter.new(
                  provider_family: :azure_foundry
                )
              )
            end

            def claim_new_instances(discovered)
              discovered.each do |name, instance_cfg|
                # Identity is the operator's CONFIG NAME — the key the router
                # resolves instances.<name> settings (per-instance tuning,
                # enable_*) by. The derived endpoint id is the secondary
                # physical field only.
                instance_id = name.to_s
                next if state_mutex.synchronize { @instance_states.key?(instance_id) }

                physical_id = derive_physical_id(instance_cfg: instance_cfg)
                state = build_instance_context(
                  name: name, instance_id: instance_id, physical_id: physical_id, instance_cfg: instance_cfg
                )
                Legion::Extensions::Llm::Inventory::WeightReconciler.track_initializing!(
                  states: @instance_states, state_key: instance_id, state: state, mutex: state_mutex
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def release_removed_instances(discovered)
              discovered_names = discovered.keys.map(&:to_s)
              existing_names = state_mutex.synchronize { @instance_states.keys }
              (existing_names - discovered_names).each { |instance_id| remove_instance_state(instance_id) }
            end

            def build_instance_context(name:, instance_id:, physical_id:, instance_cfg:)
              instance_key = build_instance_key(instance_id: instance_id, physical_id: physical_id)
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              callable = Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable.new(
                instance_cfg: instance_cfg, logger: log
              )
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key, enqueue: build_probe_enqueue(instance_id: instance_id)
              )
              publisher_token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                                         probe_request_handle: probe_coordinator,
                                                         physical_id: physical_id)
              {
                name: name, instance_key: instance_key, instance_cfg: instance_cfg,
                callable: callable, probe_coordinator: probe_coordinator,
                publisher_token: publisher_token, sequence: 0, last_probe_outcome: nil,
                offerings: offerings
              }
            end

            def build_instance_key(instance_id:, physical_id: nil)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :azure_foundry, instance_id: instance_id, physical_id: physical_id
              )
            end

            def remove_instance_state(instance_id)
              state = state_mutex.synchronize { @instance_states.delete(instance_id) }
              return unless state

              publisher.remove_instance(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                physical_id: state[:instance_key].physical_id
              )
              clear_instance_health(config_name: state[:name])
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.remove_instance',
                                  instance_id: instance_id)
            end
          end

          # Weight publication adapters bind Azure Foundry's existing publisher
          # kwargs and stable comparison to the shared atomic reconciler.
          module WeightPublicationHelpers
            private

            def refresh_cached_offerings(instance_id:, state:)
              offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              commit_weight_snapshot(instance_id: instance_id, state: state, offerings: offerings)
            end

            def commit_weight_snapshot(instance_id:, state:, offerings:)
              Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state: state,
                discovered_offerings: offerings,
                mutex: state_mutex,
                equivalent: lambda do |previous, current|
                  !offerings_changed?(previous: previous, current: current)
                end,
                replace: method(:replace_weight_snapshot)
              )
            end

            def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
              publisher.replace_instance_snapshot(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                offerings: offerings, sequence: sequence,
                physical_id: state[:instance_key].physical_id
              )
            end

            def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
              publisher.activate_instance_snapshot(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                offerings: offerings, sequence: sequence, probe_token: probe_token,
                physical_id: state[:instance_key].physical_id
              )
            end
          end

          # Initial and recovery readiness share the tracked-state activation
          # gate, so removal wins without resurrecting an instance.
          module InitialReadinessHelpers
            private

            def run_initialization_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                physical_id: state[:instance_key].physical_id
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              apply_initial_readiness(
                instance_id: instance_id, state: state, probe_token: probe_token, readiness: readiness
              )
            rescue StandardError => e
              finish_probe_safely(coordinator: coordinator)
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.initialization_probe',
                                  instance_id: instance_id)
            end

            def apply_initial_readiness(instance_id:, state:, probe_token:, readiness:)
              if readiness.ready?
                activate_after_readiness?(instance_id: instance_id, state: state, probe_token: probe_token)
              else
                report_initial_failure(
                  instance_id: instance_id, state: state, probe_token: probe_token, reason: readiness.reason
                )
              end
            end

            def activate_after_readiness?(instance_id:, state:, probe_token:)
              activated = Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state_key: instance_id,
                state: state,
                states: @instance_states,
                mutex: state_mutex,
                probe_token: probe_token,
                activate: method(:activate_weight_snapshot),
                activation_sequence: ->(tracked) { tracked.fetch(:sequence) + 1 }
              )
              return false unless activated

              state[:last_probe_outcome] = :success
              write_instance_health(
                config_name: state[:name], available: true, reason: 'startup readiness succeeded',
                probe_outcome: :success, source: :startup_readiness,
                capabilities: instance_capabilities(state[:offerings])
              )
              true
            end

            def report_initial_failure(instance_id:, state:, probe_token:, reason:)
              state[:last_probe_outcome] = :failure
              publisher.readiness_failed(
                instance_id: instance_id, probe_token: probe_token, reason: reason,
                physical_id: state[:instance_key].physical_id
              )
              write_instance_health(
                config_name: state[:name], available: false, reason: reason,
                probe_outcome: :failure, source: :startup_readiness
              )
            end
          end

          # Periodic refresh helpers — reconcile configured instances, recover
          # instances still :initializing, diff offerings, drive cadence probes.
          module RefreshHelpers
            private

            def tick_refresh
              reconcile_configured_instances
              states = state_mutex.synchronize do
                @instance_states.each_pair.map { |instance_id, state| [instance_id, state] }
              end
              states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.refresh_instance',
                                    instance_id: instance_id)
              end
              Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
                settings: Legion::Settings,
                provider_family: :azure_foundry,
                states: @instance_states,
                mutex: state_mutex,
                tracker: dormant_weight_tracker,
                dormant_logger: lambda do |key|
                  log.info(
                    "[llm][azure_foundry] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                  )
                end
              )
            end

            # Re-scans configured instances every tick so instances configured
            # after boot appear without a restart, and removed instances are
            # released from the registry.
            def reconcile_configured_instances
              discovered = configured_instances
              claim_new_instances(discovered)
              release_removed_instances(discovered)
            end

            def refresh_instance(instance_id:, state:)
              status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
              return log.debug { "[azure_foundry] no publication status for #{instance_id}; skipping refresh" } if
                status.nil?

              if status.state == :initializing
                refresh_cached_offerings(instance_id: instance_id, state: state) unless state[:last_probe_outcome].nil?
                run_initialization_probe(instance_id: instance_id, state: state)
              else
                refresh_activated_instance(instance_id: instance_id, state: state)
              end
            end

            def refresh_activated_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              changed = commit_weight_snapshot(
                instance_id: instance_id, state: state, offerings: new_offerings
              )
              if changed
                write_instance_health(
                  config_name: state[:name], available: true, reason: 'offerings refreshed',
                  probe_outcome: state[:last_probe_outcome], source: :discovery,
                  capabilities: instance_capabilities(state[:offerings])
                )
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end
          end

          # Display-only health + capabilities projection into
          # settings[:instances][<config_name>] after each registry commit.
          # The in-memory AvailabilityFact remains the routing authority; the
          # settings writes are plain serializable data read by the legion-llm
          # status API (D14). <config_name> is the settings key the instance was
          # discovered under — never the derived host:port id.
          module DiscoveryHealthDisplay
            # Fleet operation → legacy capability name, matching
            # ScopedRefresher::LegacyCoordinatorAdapter's LEGACY_CAPABILITIES.
            LEGACY_CAPABILITY_NAMES = {
              chat: :completion,
              stream_chat: :streaming,
              embed: :embedding,
              image: :image,
              transcribe: :audio_transcription,
              translate: :audio_transcription,
              speak: :audio_speech,
              moderate: :moderation
            }.freeze

            private

            # rubocop:disable Metrics/ParameterLists
            def write_instance_health(config_name:, available:, reason:, probe_outcome:, source:, capabilities: nil)
              instance_settings = ensure_instance_settings(config_name)
              instance_settings[:health] = build_health_display(
                available: available, reason: reason, probe_outcome: probe_outcome, source: source
              )
              instance_settings[:capabilities] = capabilities unless capabilities.nil?
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.write_instance_health',
                                  instance_name: config_name.to_s)
            end
            # rubocop:enable Metrics/ParameterLists

            def ensure_instance_settings(config_name)
              instances = settings[:instances]
              instances = settings[:instances] = {} unless instances.is_a?(Hash)
              instance_settings = instances[config_name]
              instance_settings = instances[config_name] = {} unless instance_settings.is_a?(Hash)
              instance_settings
            end

            def build_health_display(available:, reason:, probe_outcome:, source:)
              {
                circuit_state: available ? :closed : :open,
                denied: false,
                available: available,
                adjustment: available ? 0 : -50,
                reason: reason,
                observed_at: Time.now.getutc.iso8601,
                last_probe_outcome: probe_outcome,
                source: source
              }
            end

            def clear_instance_health(config_name:)
              instances = settings[:instances]
              return unless instances.is_a?(Hash)

              instance_settings = instances[config_name]
              return unless instance_settings.is_a?(Hash)

              instance_settings.delete(:health)
              instance_settings.delete(:capabilities)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.clear_instance_health',
                                  instance_name: config_name.to_s)
            end

            def instance_capabilities(offerings)
              operations = Set.new
              offerings.each do |draft|
                draft.operation_evidence.each_value do |evidence|
                  operations << evidence.operation if evidence.supported?
                end
              end
              operations.filter_map { |op| LEGACY_CAPABILITY_NAMES[op] }.uniq.sort
            end
          end

          # SSOT v3 periodic discovery actor for Azure AI Foundry provider
          # instances. Claims configured instances (single source:
          # AzureFoundry.discover_instances), discovers deployments from config,
          # probes health via models/info, and publishes complete OfferingDraft
          # snapshots through the Inventory::Publisher. Supports recovery of
          # instances that failed initial readiness, per-tick reconciliation of
          # late-removed instances, and coalesced reactive probes after
          # dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include HealthCheckHelpers
            include OfferingBuilderHelpers
            include OfferingComparisonHelpers
            include InstanceConfigHelpers
            include InstanceIdentityHelpers
            include ProbeHelpers
            include ShutdownHelpers
            include ActivationHelpers
            include WeightPublicationHelpers
            include InitialReadinessHelpers
            include RefreshHelpers
            include DiscoveryHealthDisplay

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              discovery_interval_seconds
            end

            def manual
              @instance_states ||= Concurrent::Map.new
              state_mutex
              dormant_weight_tracker
              tick_refresh
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discovery_refresh.shutdown')
            end

            private

            def state_mutex
              @state_mutex ||= Mutex.new
            end

            def dormant_weight_tracker
              @dormant_weight_tracker ||= Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
            end

            # D9: the tick interval is the registered discovery.interval_seconds.
            # A missing or non-positive value falls back to the registered
            # default — never nil (a nil interval stops the TimerTask after the
            # first tick).
            def discovery_interval_seconds
              discovery = settings[:discovery]
              interval = discovery.is_a?(Hash) ? discovery[:interval_seconds] : nil
              interval.is_a?(Integer) && interval.positive? ? interval : registered_discovery_interval_seconds
            end

            def registered_discovery_interval_seconds
              Legion::Extensions::Llm::AzureFoundry.default_settings[:discovery][:interval_seconds]
            end
          end

          # Callable wrapper for an Azure Foundry provider instance. Implements
          # the fleet dispatch operations by delegating to the per-instance
          # AzureFoundry::Provider (errors propagate so
          # normalize_dispatch_error can classify them), plus the `disconnect`
          # and `normalize_dispatch_error(error:)` contracts required by
          # Inventory::CallableHandle and Routing::ProviderOutcome.
          #
          # The fleet passes `model:` as a raw string (the offering's model id).
          # chat/stream_chat render paths call `model.id` (the stock
          # OpenAICompatible#render_payload), so a Model::Info is required
          # there; embed/count_tokens are string-tolerant (Provider#model_id
          # accepts the value verbatim), so those pass through — wrapping them
          # would serialize a Data object into the wire payload/response.
          class AzureFoundryCallable
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

            def chat(messages:, model:, **rest)
              provider.chat(messages: messages, model: to_model_info(model), **rest)
            end

            def stream_chat(messages:, model:, **rest, &)
              provider.stream(messages: messages, model: to_model_info(model), **rest, &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model: model, **rest)
            end

            def count_tokens(messages:, model:, **rest)
              provider.count_tokens(messages: messages, model: model, **rest)
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

            def to_model_info(model)
              return model if model.respond_to?(:id)

              Legion::Extensions::Llm::Model::Info.new(id: model.to_s, provider: :azure_foundry)
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
