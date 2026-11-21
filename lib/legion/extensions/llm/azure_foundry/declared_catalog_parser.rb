# frozen_string_literal: true

require 'legion/extensions/llm/azure_foundry/model_catalog_parser'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Operator declarations supply identity only. The authenticated resource
        # catalog supplies model facts; it does not prove a deployment exists.
        module DeclaredCatalogParser
          module_function

          def bindings(value:, **)
            unless value.is_a?(Array)
              raise Legion::Extensions::Llm::ConfigurationError, 'provider.deployments must be an array of bindings'
            end

            names = Set.new
            value.each do |binding|
              validate_binding!(binding: binding)
              next if names.add?(binding.fetch(:name))

              raise Legion::Extensions::Llm::ConfigurationError, 'provider.deployments contains duplicate binding names'
            end
            value
          end

          def validate_binding!(binding:, **)
            allowed = %i[name model model_version deployment_type]
            valid = binding.is_a?(Hash) && (binding.keys - allowed).empty? &&
                    binding_identity_valid?(binding: binding)
            return if valid

            raise Legion::Extensions::Llm::ConfigurationError,
                  'deployment bindings require name and model, with optional model_version and deployment_type only'
          end

          def binding_identity_valid?(binding:, **)
            %i[name model].all? { |key| identity_text?(value: binding[key]) } &&
              %i[model_version deployment_type].all? { |key| !binding.key?(key) || identity_text?(value: binding[key]) }
          end

          def identity_text?(value:, **) = value.is_a?(String) && !value.empty? && value == value.strip

          def catalog_entries(body:, **)
            entries = body.is_a?(Hash) ? body[:data] : nil
            unless entries.is_a?(Array)
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure resource model catalog must contain a data array'
            end
            entries
          end

          def parse(body:, declarations:, **)
            model_ids = declarations.to_set { |binding| binding.fetch(:model) }
            catalog = catalog_by_id(entries: catalog_entries(body: body), model_ids: model_ids)
            declarations.map do |binding|
              model = binding.fetch(:model)
              unless catalog.key?(model)
                raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                      "declared deployment base model is absent from the resource catalog: #{model}"
              end

              catalog.fetch(model).merge(
                deployment_name: binding.fetch(:name), model_name: model,
                declared_model_version: binding[:model_version], declared_deployment_type: binding[:deployment_type],
                model_metadata_key: [model, binding[:model_version], binding[:deployment_type]]
              )
            end
          end

          def catalog_by_id(entries:, model_ids:, **)
            entries.each_with_object({}) do |entry, catalog|
              unless entry.is_a?(Hash) && identity_text?(value: entry[:id])
                raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                      'Azure resource model catalog contains an invalid model id'
              end
              id = entry.fetch(:id)
              next unless model_ids.include?(id)

              if catalog.key?(id) && catalog.fetch(id) != entry
                raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                      "conflicting Azure resource model records for #{id}"
              end
              catalog[id] = entry
            end
          end
        end
      end
    end
  end
end
