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

            entry.merge(observed_identity(entry: entry)).merge(observed_limits(entry: entry))
          end

          def observed_identity(entry:, **)
            {
              deployment_name: entry.fetch(:name), model_name: entry[:modelName],
              model_revision: entry[:modelVersion], model_publisher: entry[:modelPublisher],
              model_metadata_key: [entry[:modelName], entry[:modelVersion], sku_name(entry: entry)]
            }
          end

          def sku_name(entry:, **)
            sku = entry[:sku]
            return nil if sku.nil?

            name = sku[:name] if sku.is_a?(Hash)
            return name if name.is_a?(String) && !name.empty?

            raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                  'Azure deployment sku must contain a nonempty name'
          end

          def observed_limits(entry:, **)
            capabilities = entry[:capabilities]
            unless capabilities.nil? || capabilities.is_a?(Hash)
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure deployment capabilities must be an object'
            end

            {
              context_window: Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.positive_integer(
                value: capabilities&.[](:maxContextToken)
              ),
              max_output_tokens: Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.positive_integer(
                value: capabilities&.[](:maxOutputToken)
              )
            }
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
