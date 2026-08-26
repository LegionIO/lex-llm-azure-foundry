# frozen_string_literal: true

require 'uri'
require 'time'
require 'faraday'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/azure_foundry/model_catalog_parser'
require 'legion/extensions/llm/azure_foundry/helpers/offering_evidence'
require 'legion/extensions/llm/azure_foundry/helpers/callable'
require 'legion/extensions/llm/azure_foundry/provider'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Runners
          # Azure AI Foundry discovery runner: ONLY the Azure Foundry-specific
          # work. The generic reconcile / claim / activate / probe (cadence +
          # reactive) / replace / weight-publication / health-display pipeline
          # is mixed in from the shared Discovery::Pipeline. Weight is NOT
          # computed here — the shared WeightReconciler recomputes it from live
          # settings at publish.
          #
          # The catalog is NOT the OpenAI-compatible GET /v1/models shape: each
          # instance serves a surface — models/info?api-version=<v> on the
          # model-inference surface, /models on the OpenAI-compatible surface
          # — with an envelope the shared ModelCatalogParser resolves. The
          # readiness probe is the SAME non-inference catalog GET. The
          # overrides are therefore the family symbol (AzureFoundry ->
          # :azure_foundry), the surface-aware base url / catalog path, the
          # api-key + bearer auth, the catalog fetch/parse, the physical id,
          # and the offering-draft evidence.
          module Discovery
            extend self
            extend Legion::Extensions::Llm::AzureFoundry::Helpers::OfferingEvidence
            include Legion::Extensions::Llm::Discovery::Pipeline

            # The derived family would be :azurefoundry (lowercased module
            # name); the registered family everywhere (Publisher, InstanceKey,
            # WeightReconciler) is :azure_foundry.
            def provider_family = :azure_foundry

            # ── Azure Foundry instance-config keys / connection ──────────────
            # The normalized instance config (AzureFoundry.discover_instances)
            # carries azure_foundry_endpoint / azure_foundry_api_key /
            # azure_foundry_bearer_token / azure_foundry_surface /
            # azure_foundry_api_version; the pipeline's catalog_base_url and
            # auth_token read the standard keys, so override to these.
            def catalog_base_url(instance_cfg:)
              url = instance_cfg[:azure_foundry_endpoint].to_s.sub(%r{/*\z}, '')
              raise ArgumentError, 'azure_foundry_endpoint is required for the connection' if url.strip.empty?
              return "#{url}/openai/v1" if surface_for(instance_cfg) == :openai_v1 && !url.end_with?('/openai/v1')

              url
            end

            def auth_token(instance_cfg:)
              token = instance_cfg[:azure_foundry_api_key]
              token if credential_string?(token)
            end

            # Azure Foundry authenticates with an api-key header and/or a
            # bearer Authorization header — not a plain bearer only.
            def apply_auth_headers(faraday:, instance_cfg:)
              api_key = instance_cfg[:azure_foundry_api_key]
              faraday.headers['api-key'] = api_key if credential_string?(api_key)

              bearer_token = instance_cfg[:azure_foundry_bearer_token]
              faraday.headers['Authorization'] = "Bearer #{bearer_token}" if credential_string?(bearer_token)
            end

            # ── Catalog fetch / readiness (same non-inference GET) ───────────
            # The model catalog discovery path, per surface. The provider's
            # models_url and this path must agree — both derive from the
            # surface and api-version the same way.
            def catalog_path(instance_cfg:)
              return 'models' if surface_for(instance_cfg) == :openai_v1

              version = instance_cfg[:azure_foundry_api_version] || instance_cfg[:api_version] || '2024-05-01-preview'
              "models/info?api-version=#{version}"
            end

            # A failed catalog fetch is a CatalogFetchFailure (the pipeline
            # keeps the last good snapshot), never a nil.
            def fetch_raw_models(instance_cfg:)
              conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg),
                                      instance_cfg: instance_cfg, timeout: 10, open_timeout: 5)
              response = conn.get(catalog_path(instance_cfg: instance_cfg))
              raise CatalogFetchFailure, "catalog fetch returned HTTP #{response.status}" unless response.status == 200

              Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_entries(catalog_body(response))
            end

            # Catalog responses arrive as raw strings (this connection has no
            # JSON middleware) — parse through the shared helper.
            def catalog_body(response)
              body = response.body
              return Legion::JSON.parse(body, symbolize_names: false) if body.is_a?(String) && !body.strip.empty?

              body
            end

            def model_id_from(model_data)
              Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_id_for(model_data)
            end

            # Readiness is a non-inference GET of the model catalog endpoint
            # (models/info on the model-inference surface, models on the
            # OpenAI-compatible surface), never a chat/embed call. The catalog
            # discovery hits the SAME endpoint through the same auth.
            def check_health(instance_cfg:)
              conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg),
                                      instance_cfg: instance_cfg, timeout: 5, open_timeout: 3)
              status = conn.get(catalog_path(instance_cfg: instance_cfg)).status
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: status == 200, reason: "Azure Foundry health returned #{status}",
                metadata: { status: status, endpoint: instance_cfg[:azure_foundry_endpoint].to_s }
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'azure_foundry.runner.discovery.health')
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: "Azure Foundry health error: #{e.message}",
                metadata: { error_class: e.class.name }
              )
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::AzureFoundry::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ───────────────
            # endpoint host:port, or host:port/ak:<credential fingerprint> when
            # an api key is present. Never identity — the instance identity is
            # the operator's config name.
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
              handle_exception(e, level: :warn, operation: 'azure_foundry.runner.discovery.extract_host_port',
                                  url: url.to_s)
              raise
            end

            # ── Offering draft (evidence + metadata; NO weight) ──────────────
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = (instance_cfg[:tier] || :cloud).to_sym
              embed = embedding_model?(model_id, model_data)
              base_name = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.base_model_name_for(model_data)
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed),
                capability_evidence: build_capability_evidence(entry: model_data, embed_supported: embed),
                context_evidence: build_context_evidence(entry: model_data, instance_cfg: instance_cfg),
                max_output_evidence: build_max_output_evidence(entry: model_data, instance_cfg: instance_cfg),
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(model_id: model_id),
                metadata: build_offering_metadata(model_id: model_id, base_name: base_name,
                                                  instance_key: instance_key).freeze,
                publication_source: :provider_catalog
              )
            end

            private

            def surface_for(instance_cfg)
              (instance_cfg[:azure_foundry_surface] || instance_cfg[:surface] || :model_inference).to_sym
            end

            def credential_string?(value) = value.is_a?(String) && !value.strip.empty?
          end
        end
      end
    end
  end
end
