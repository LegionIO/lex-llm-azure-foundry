# frozen_string_literal: true

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/azure_foundry/model_catalog_parser'
require 'legion/extensions/llm/azure_foundry/helpers/offering_evidence'
require 'legion/extensions/llm/azure_foundry/helpers/callable'
require 'legion/extensions/llm/azure_foundry/helpers/project_catalog'
require 'legion/extensions/llm/azure_foundry/helpers/endpoint_access'
require 'legion/extensions/llm/azure_foundry/provider'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Runners
          # The shared pipeline owns the lifecycle, weights, and inventory.
          # Azure owns its endpoint protocol, deployment identities, and evidence.
          module Discovery
            extend self
            extend Legion::Extensions::Llm::AzureFoundry::Helpers::OfferingEvidence
            include Legion::Extensions::Llm::Discovery::Pipeline
            include Legion::Extensions::Llm::AzureFoundry::Helpers::EndpointAccess
            include Legion::Extensions::Llm::AzureFoundry::Helpers::ProjectCatalog

            def provider_family = :azure_foundry

            def fetch_raw_models(instance_cfg:, **)
              if credential_string?(instance_cfg[:azure_foundry_project_endpoint])
                return fetch_project_deployments(instance_cfg: instance_cfg)
              end

              response = catalog_response(instance_cfg: instance_cfg)
              raise CatalogFetchFailure, "catalog fetch returned HTTP #{response.status}" unless response.status == 200

              Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_entries(
                body: catalog_body(response), surface: surface_for(instance_cfg)
              )
            rescue Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                   Legion::JSON::ParseError => e
              raise CatalogFetchFailure, e.message, cause: e
            end

            def model_id_from(model_data)
              Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_id_for(model_data).to_s
            end

            # Readiness checks data-plane authentication, not generation. It
            # cannot substitute for deployment identity or capability evidence.
            def check_health(instance_cfg:, **)
              status = catalog_response(instance_cfg: instance_cfg, health: true).status
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: status == 200, reason: "Azure Foundry health returned #{status}",
                metadata: { status: status, endpoint: instance_cfg[:azure_foundry_endpoint].to_s }
              )
            rescue StandardError => e
              raise if discovery_programming_error?(e)

              handle_exception(e, level: :warn, operation: 'azure_foundry.runner.discovery.health')
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: "Azure Foundry health error: #{e.class}",
                metadata: { error_class: e.class.name }
              )
            end

            def build_callable(instance_cfg:, **)
              Legion::Extensions::Llm::AzureFoundry::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:, **)
              tier = instance_cfg.fetch(:tier, Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance][:tier])
              operations = build_operation_evidence(entry: model_data)
              base_name = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.base_model_name_for(model_data)
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                operation_evidence: operations,
                capability_evidence: build_capability_evidence(entry: model_data, operations: operations),
                context_evidence: build_context_evidence(entry: model_data),
                max_output_evidence: build_max_output_evidence(entry: model_data),
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: value_evidence(model_data[:model_revision] || model_data['model_revision']),
                tokenizer_evidence: absent_value_evidence,
                quota_domains: build_quota_domains(model_id: model_id),
                metadata: build_offering_metadata(model_id: model_id, base_name: base_name, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            private

            def catalog_response(instance_cfg:, health: false)
              limits = settings[:discovery]
              conn = build_connection(
                base_url: catalog_base_url(instance_cfg: instance_cfg), instance_cfg: instance_cfg,
                timeout: limits[health ? :health_timeout : :request_timeout],
                open_timeout: limits[health ? :health_open_timeout : :open_timeout]
              )
              conn.get(catalog_path(instance_cfg: instance_cfg))
            end

            def catalog_body(response)
              body = response.body
              body.is_a?(String) ? Legion::JSON.load(body) : body
            end
          end
        end
      end
    end
  end
end
