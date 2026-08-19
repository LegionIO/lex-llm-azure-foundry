# frozen_string_literal: true

require 'uri'
require 'time'
require 'concurrent'
require 'faraday'

require 'legion/json'
require 'legion/extensions/llm/azure_foundry/model_catalog_parser'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/scoped_refresher'
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
          # Readiness is a non-inference GET of the model catalog endpoint
          # (models/info on the model-inference surface, /models on the
          # OpenAI-compatible surface), never a chat/embed call. The catalog
          # discovery below hits the SAME endpoint through the same auth.
          module HealthCheckHelpers
            private

            def check_health(instance_cfg:)
              endpoint = instance_cfg[:azure_foundry_endpoint]
              conn = build_health_connection(endpoint: endpoint, instance_cfg: instance_cfg)
              response = conn.get(catalog_path(instance_cfg: instance_cfg))
              build_readiness_from_response(response: response, endpoint: endpoint)
            rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.check_health')
              readiness_failure(reason: "Azure Foundry health network error: #{e.message}", error: e)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.check_health')
              readiness_failure(reason: "Azure Foundry health error: #{e.message}", error: e)
            end

            # The model catalog discovery path, per surface. The provider's
            # models_url and this path must agree — both derive from the
            # surface and api-version the same way.
            def catalog_path(instance_cfg:)
              surface = (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] || :model_inference).to_sym
              return 'models' if surface == :openai_v1

              version = instance_cfg[:azure_foundry_api_version] || instance_cfg[:api_version] || '2024-05-01-preview'
              "models/info?api-version=#{version}"
            end

            # Catalog responses arrive as raw strings (this connection has no
            # JSON middleware) — parse through the shared helper.
            def catalog_body(response)
              body = response.body
              return body unless body.is_a?(String)
              return body if body.strip.empty?

              Legion::JSON.parse(body, symbolize_names: false)
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

              bearer_token = instance_cfg[:azure_foundry_bearer_token]
              faraday.headers['Authorization'] = "Bearer #{bearer_token}" if
                bearer_token.is_a?(String) && !bearer_token.strip.empty?
            end

            # Accepts the real Faraday shapes (Faraday::Response from conn.get,
            # Faraday::Env on error paths) as well as a plain Hash.
            def http_status(response)
              return response[:status] if response.is_a?(Hash)

              response.status
            end
          end

          # Capability and operation evidence builders — the immutable facts an
          # OfferingDraft carries about what a discovered model can and
          # cannot do.
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

            def build_capability_evidence(entry:, embed_supported:)
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
                source: if entry.key?(:enable_thinking) || entry.key?('enable_thinking')
                          :instance_override
                        else
                          :default_false
                        end
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

          # Live model-catalog discovery. Fetches the model catalog from the
          # instance's discovery endpoint (the same non-billable GET the
          # readiness probe uses) and assembles a complete OfferingDraft per
          # catalog entry. Nothing is derived from instance config: whatever
          # the endpoint reports is the offering set.
          module OfferingBuilderHelpers
            include CapabilityEvidenceHelpers

            private

            # D16: programming errors (NameError/NoMethodError/ArgumentError)
            # are bugs in the builder, not "no offerings" — they must fail
            # loud. A catalog fetch failure yields nil (not []): the refresh
            # loop then keeps the last complete snapshot rather than
            # replacing it with an empty set.
            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              entries = fetch_catalog_entries(instance_cfg:)
              return nil if entries.nil?

              build_offering_drafts(entries: entries, instance_cfg: instance_cfg, instance_key: instance_key)
            rescue StandardError => e
              raise e if programming_error?(e)

              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.discover_offerings')
              nil
            end

            # Builds one OfferingDraft per catalog entry. The pure seam the
            # SSOT harness drives with fixed entries (mirroring bedrock's
            # harness-supplied model summary) — no network involved.
            def build_offering_drafts(entries:, instance_cfg:, instance_key:)
              entries.filter_map do |entry|
                model_id = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_id_for(entry)
                next if model_id.to_s.strip.empty?

                build_offering_draft(entry: entry, model_id: model_id,
                                     instance_cfg: instance_cfg, instance_key: instance_key)
              end
            end

            def programming_error?(error)
              error.is_a?(NameError) || error.is_a?(NoMethodError) || error.is_a?(ArgumentError)
            end

            def fetch_catalog_entries(instance_cfg:)
              conn = build_health_connection(
                endpoint: instance_cfg[:azure_foundry_endpoint], instance_cfg: instance_cfg
              )
              response = conn.get(catalog_path(instance_cfg: instance_cfg))
              return nil unless response.status == 200

              Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_entries(
                catalog_body(response)
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.actor.fetch_catalog')
              nil
            end

            def build_offering_draft(entry:, model_id:, instance_cfg:, instance_key:)
              tier = (instance_cfg[:tier] || :cloud).to_sym
              embed = embedding_model?(model_id, entry)
              base_name = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.base_model_name_for(entry)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed),
                capability_evidence: build_capability_evidence(entry: entry, embed_supported: embed),
                context_evidence: build_context_evidence(entry: entry, instance_cfg: instance_cfg),
                max_output_evidence: build_max_output_evidence(entry: entry, instance_cfg: instance_cfg),
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(model_id: model_id),
                metadata: build_offering_metadata(entry: entry, model_id: model_id, base_name: base_name,
                                                  instance_key: instance_key).freeze,
                publication_source: :provider_catalog
              )
            end

            # Embedding detection: an explicit catalog usage field when
            # present, otherwise the model name. A name match is a naming
            # hint, not authoritative proof.
            def embedding_model?(model_id, entry)
              usage = (entry['usage_type'] || entry[:usage_type] || entry['type'] || entry[:type]).to_s.downcase
              return true if %w[embed embedding].include?(usage)

              model_id.to_s.match?(/embed/i)
            end

            def build_context_evidence(entry:, instance_cfg:)
              ctx = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.context_window_for(entry) ||
                    instance_cfg[:context_window] || instance_cfg[:max_input_tokens]
              return absent_value_evidence unless ctx.is_a?(Integer) && ctx.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known, value: ctx, source: :provider_catalog
              )
            end

            def build_max_output_evidence(entry:, instance_cfg:)
              max_out = entry['max_output_tokens'] || entry[:max_output_tokens] ||
                        instance_cfg[:max_output_tokens]
              return absent_value_evidence unless max_out.is_a?(Integer) && max_out.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known, value: max_out, source: :provider_catalog
              )
            end

            def build_quota_domains(model_id:)
              return {} if model_id.to_s.strip.empty?

              {
                chat: "azure:deployment:#{model_id}",
                stream_chat: "azure:deployment:#{model_id}",
                embed: "azure:deployment:#{model_id}"
              }
            end

            def build_offering_metadata(entry:, model_id:, base_name:, instance_key:)
              meta = { raw_catalog: entry }
              meta[:canonical_model_alias] = base_name if base_name
              meta[:model_family] =
                Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_family_for(base_name || model_id)
              meta[:instance_id] = instance_key.instance_id
              meta[:physical_id] = instance_key.physical_id if instance_key.physical_id
              meta.compact
            end
          end

          # Offerings change detection. Time.now observed_at stamps in the
          # evidence poison Data#==, so a rebuilt-but-unchanged catalog would
          # otherwise replace the snapshot (and bump the sequence) every tick.
          # Compare identity/status fields only.
          module OfferingComparisonHelpers
            private

            def offerings_changed?(previous:, current:)
              return true unless previous.size == current.size

              current.any? do |draft|
                previous.none? { |candidate| drafts_stable?(candidate, draft) }
              end
            end

            def drafts_stable?(candidate, draft)
              basic_fields_stable?(candidate, draft) &&
                evidence_maps_stable?(candidate.operation_evidence, draft.operation_evidence) &&
                evidence_maps_stable?(candidate.capability_evidence, draft.capability_evidence) &&
                value_fields_stable?(candidate, draft) &&
                candidate.quota_domains == draft.quota_domains &&
                candidate.metadata == draft.metadata
            end

            def basic_fields_stable?(candidate, draft)
              candidate.model == draft.model &&
                candidate.tier == draft.tier &&
                evidence_key_set_stable?(candidate.operation_evidence, draft.operation_evidence) &&
                evidence_key_set_stable?(candidate.capability_evidence, draft.capability_evidence)
            end

            def evidence_key_set_stable?(previous_map, current_map)
              previous_map.keys.sort == current_map.keys.sort
            end

            def evidence_maps_stable?(previous_map, current_map)
              previous_map.all? do |key, evidence|
                other = current_map[key]
                other&.status == evidence.status && other&.source == evidence.source
              end
            end

            def value_fields_stable?(candidate, draft)
              values_stable?(candidate.context_evidence, draft.context_evidence) &&
                values_stable?(candidate.max_output_evidence, draft.max_output_evidence) &&
                values_stable?(candidate.embedding_dimensions_evidence, draft.embedding_dimensions_evidence) &&
                values_stable?(candidate.model_revision_evidence, draft.model_revision_evidence)
            end

            def values_stable?(previous_value, current_value)
              previous_value.status == current_value.status &&
                previous_value.value == current_value.value &&
                previous_value.source == current_value.source
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
              state = @instance_states && @instance_states[instance_id]
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

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id, publisher_token: state[:publisher_token],
                  physical_id: state[:instance_key].physical_id
                )
                clear_instance_health(config_name: state[:name])
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end
          end

          # Per-instance activation helpers — claim, state tracking, removal.
          module ActivationHelpers
            private

            def activate_after_readiness(instance_id:, state:, probe_token:)
              state[:sequence] += 1
              state[:last_probe_outcome] = :success
              publisher.activate_instance_snapshot(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                offerings: state[:offerings], sequence: state[:sequence], probe_token: probe_token,
                physical_id: state[:instance_key].physical_id
              )
              write_instance_health(
                config_name: state[:name], available: true, reason: 'startup readiness succeeded',
                probe_outcome: :success, source: :startup_readiness,
                capabilities: instance_capabilities(state[:offerings])
              )
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
                next if @instance_states.key?(instance_id)

                physical_id = derive_physical_id(instance_cfg: instance_cfg)
                @instance_states[instance_id] = build_instance_context(
                  name: name, instance_id: instance_id, physical_id: physical_id, instance_cfg: instance_cfg
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def release_removed_instances(discovered)
              discovered_names = discovered.keys.map(&:to_s)
              (@instance_states.keys - discovered_names).each { |instance_id| remove_instance_state(instance_id) }
            end

            def build_instance_context(name:, instance_id:, physical_id:, instance_cfg:)
              instance_key = build_instance_key(instance_id: instance_id, physical_id: physical_id)
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
                offerings: discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              }
            end

            def build_instance_key(instance_id:, physical_id: nil)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :azure_foundry, instance_id: instance_id, physical_id: physical_id
              )
            end

            def remove_instance_state(instance_id)
              state = @instance_states.delete(instance_id)
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

          # Periodic refresh helpers — reconcile configured instances, recover
          # instances still :initializing, diff offerings, drive cadence probes.
          module RefreshHelpers
            private

            def tick_refresh
              reconcile_configured_instances
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'azure_foundry.actor.refresh_instance',
                                    instance_id: instance_id)
              end
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
                run_initialization_probe(instance_id: instance_id, state: state)
              else
                refresh_activated_instance(instance_id: instance_id, state: state)
              end
            end

            # D4: an instance whose initial readiness failed stays :initializing.
            # activate_instance_snapshot is the only transition legal from
            # :initializing, so a later passing probe re-activates the claim
            # (fresh probe token, current offerings, next sequence) instead of
            # calling replace/readiness_succeeded, which would raise
            # InvalidTransitionError.
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
              unless readiness.ready?
                report_initial_failure(
                  instance_id: instance_id, state: state, probe_token: probe_token, reason: readiness.reason
                )
                return
              end

              # A readiness pass proves the endpoint answers; the catalog
              # fetch can still fail (e.g. an unparseable body). Do not
              # activate with a nil catalog — retry on the next tick.
              offerings = state[:offerings] ||
                          discover_offerings_for_instance(
                            instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
                          )
              if offerings.nil?
                report_initial_failure(
                  instance_id: instance_id, state: state, probe_token: probe_token,
                  reason: 'model catalog fetch failed'
                )
                return
              end

              state[:offerings] = offerings
              activate_after_readiness(instance_id: instance_id, state: state, probe_token: probe_token)
            end

            def refresh_activated_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )

              # A failed catalog fetch (nil) keeps the last complete snapshot
              # — an incomplete refresh must never delete a known catalog.
              return run_cadence_probe(instance_id: instance_id, state: state) if new_offerings.nil?

              if offerings_changed?(previous: state[:offerings], current: new_offerings)
                replace_instance_offerings(instance_id: instance_id, state: state, offerings: new_offerings)
                state[:offerings] = new_offerings
                write_instance_health(
                  config_name: state[:name], available: true, reason: 'offerings refreshed',
                  probe_outcome: state[:last_probe_outcome], source: :discovery,
                  capabilities: instance_capabilities(new_offerings)
                )
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end

            def replace_instance_offerings(instance_id:, state:, offerings:)
              state[:sequence] += 1
              publisher.replace_instance_snapshot(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                offerings: offerings, sequence: state[:sequence],
                physical_id: state[:instance_key].physical_id
              )
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
          # AzureFoundry.discover_instances), discovers the live model catalog
          # from the instance's discovery endpoint (models/info on the
          # model-inference surface, /models on the OpenAI-compatible surface),
          # probes health through the same endpoint, and publishes complete
          # OfferingDraft snapshots through the Inventory::Publisher. Supports
          # recovery of
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
