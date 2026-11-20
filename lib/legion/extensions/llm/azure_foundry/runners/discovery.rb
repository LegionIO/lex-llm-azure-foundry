# frozen_string_literal: true

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/azure_foundry/model_catalog_parser'
require 'legion/extensions/llm/azure_foundry/declared_catalog_parser'
require 'legion/extensions/llm/azure_foundry/helpers/offering_evidence'
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
              case instance_cfg.fetch(:azure_foundry_discovery_source)
              when :project then fetch_project_deployments(instance_cfg: instance_cfg)
              when :declared then fetch_declared_models(instance_cfg: instance_cfg)
              when :model_info
                unless surface_for(instance_cfg) == :model_inference
                  raise Legion::Extensions::Llm::ConfigurationError,
                        'OpenAI v1 requires an explicit project or declared discovery_source'
                end
                Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_info(
                  body: authenticated_catalog(instance_cfg: instance_cfg)
                )
              else
                raise Legion::Extensions::Llm::ConfigurationError, 'unsupported provider.discovery_source'
              end
            rescue Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                   Legion::JSON::ParseError => e
              raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure, e.message, cause: e
            end

            def model_id_from(model_data)
              model_data.fetch(:deployment_name)
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
              Legion::Extensions::Llm::AzureFoundry::Provider.new(instance_cfg)
            end

            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:, **)
              tier = instance_cfg.fetch(:tier)
              operations = build_operation_evidence(entry: model_data)
              base_name = model_data[:model_name]
              declared = instance_cfg[:azure_foundry_discovery_source] == :declared
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                operation_evidence: operations,
                capability_evidence: build_capability_evidence(entry: model_data, operations: operations),
                context_evidence: build_context_evidence(entry: model_data),
                max_output_evidence: build_max_output_evidence(entry: model_data),
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: value_evidence(model_data[:model_revision]),
                tokenizer_evidence: absent_value_evidence,
                metadata: build_offering_metadata(base_name: base_name, instance_key: instance_key,
                                                  publisher: model_data[:model_publisher], declared: declared,
                                                  model_data: model_data),
                publication_source: declared ? :provider_static_catalog : :provider_catalog
              )
            end

            private

            def build_offering_metadata(base_name:, instance_key:, publisher:, declared:, model_data:)
              metadata = {
                canonical_model_alias: base_name, model_publisher: publisher,
                instance_id: instance_key.instance_id, physical_id: instance_key.physical_id
              }
              if declared
                metadata.merge!(declared: true, declared_model_version: model_data[:declared_model_version],
                                declared_deployment_type: model_data[:declared_deployment_type])
              end
              metadata.compact.freeze
            end

            def fetch_declared_models(instance_cfg:)
              unless surface_for(instance_cfg) == :openai_v1
                raise Legion::Extensions::Llm::ConfigurationError,
                      'declared discovery_source requires openai_v1 surface'
              end

              bindings = Legion::Extensions::Llm::AzureFoundry::DeclaredCatalogParser.bindings(
                value: instance_cfg[:azure_foundry_deployments]
              )
              return [] if bindings.empty?

              Legion::Extensions::Llm::AzureFoundry::DeclaredCatalogParser.parse(
                body: authenticated_catalog(instance_cfg: instance_cfg), declarations: bindings
              )
            end
          end
        end
      end
    end
  end
end
