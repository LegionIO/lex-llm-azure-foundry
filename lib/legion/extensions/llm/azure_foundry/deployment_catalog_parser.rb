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

            { entries: values.filter_map { |entry| normalize_entry(entry: entry) }, next_link: next_link(body: body) }
          end

          def normalize_entry(entry:, **)
            parser = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser
            unless entry.is_a?(Hash) && parser.lookup(entry,
                                                      [:type]) == 'ModelDeployment' && parser.lookup(entry, [:name])
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure project response contains an invalid model deployment'
            end
            return if connected_resource?(entry: entry)

            entry.merge(deployment_name: parser.lookup(entry, [:name]), model_name: parser.lookup(entry, [:modelName]),
                        model_revision: parser.lookup(entry, [:modelVersion]))
          end

          def connected_resource?(entry:, **)
            connection = entry.key?(:connectionName) ? entry[:connectionName] : entry['connectionName']
            unless connection.nil? || connection.is_a?(String)
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure deployment connectionName must be a string or null'
            end

            # A connected resource has its own endpoint and credentials. Its
            # deployments are not evidence for this instance's native endpoint.
            connection.is_a?(String) && !connection.strip.empty?
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
