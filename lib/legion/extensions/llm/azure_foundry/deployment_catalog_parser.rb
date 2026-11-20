# frozen_string_literal: true

require 'legion/extensions/llm/azure_foundry/model_catalog_parser'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Foundry project responses identify deployments by name, not model id.
        module DeploymentCatalogParser
          module_function

          def page(body:, connection_name: nil, **)
            values = body.is_a?(Hash) ? body[:value] : nil
            unless values.is_a?(Array)
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure project deployment response must contain a value array'
            end

            entries = values.filter_map { |entry| normalize_entry(entry: entry, connection_name: connection_name) }
            { entries: entries, next_link: next_link(body: body) }
          end

          def normalize_entry(entry:, connection_name: nil, **)
            unless entry.is_a?(Hash) && entry[:type] == 'ModelDeployment' &&
                   entry[:name].is_a?(String) && !entry[:name].empty?
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure project response contains an invalid model deployment'
            end
            return unless source_connection(entry: entry) == connection_name

            entry.merge(deployment_name: entry.fetch(:name), model_name: entry[:modelName],
                        model_revision: entry[:modelVersion], model_publisher: entry[:modelPublisher])
          end

          def source_connection(entry:, **)
            connection = entry[:connectionName]
            unless connection.nil? || connection.is_a?(String)
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure deployment connectionName must be a string or null'
            end

            connection.to_s.strip.empty? ? nil : connection.strip
          end

          def next_link(body:, **)
            value = body[:nextLink]
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
