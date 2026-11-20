# frozen_string_literal: true

require 'legion/extensions/llm/azure_foundry/model_catalog_parser'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Foundry project responses identify deployments by name, not model id.
        module DeploymentCatalogParser
          module_function

          def page(body:, **)
            values = body.is_a?(Hash) ? body[:value] || body['value'] : nil
            unless values.is_a?(Array)
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure project deployment response must contain a value array'
            end

            { entries: values.map { |entry| normalize_entry(entry: entry) }, next_link: next_link(body: body) }
          end

          def normalize_entry(entry:, **)
            parser = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser
            unless entry.is_a?(Hash) && parser.lookup(entry,
                                                      [:type]) == 'ModelDeployment' && parser.lookup(entry, [:name])
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure project response contains an invalid model deployment'
            end

            entry.merge(deployment_name: parser.lookup(entry, [:name]), model_name: parser.lookup(entry, [:modelName]),
                        model_revision: parser.lookup(entry, [:modelVersion]))
          end

          def next_link(body:, **)
            value = body[:nextLink] || body['nextLink']
            return nil if value.nil? || value == ''
            return value if value.is_a?(String)

            raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                  'Azure deployment nextLink must be a string'
          end
        end
      end
    end
  end
end
