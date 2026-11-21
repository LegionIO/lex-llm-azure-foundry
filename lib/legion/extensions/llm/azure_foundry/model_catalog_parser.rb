# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # The documented model-inference /info response, plus shared Azure
        # deployment-record validation. Resource model catalogs are not accepted.
        module ModelCatalogParser
          class InvalidCatalog < StandardError; end

          module_function

          def model_info(body:, **)
            unless body.is_a?(Hash) && body[:model_name].is_a?(String) && !body[:model_name].empty? &&
                   %w[chat-completion embeddings].include?(body[:model_type])
              raise InvalidCatalog, 'invalid Azure model-inference info response'
            end

            [body.merge(deployment_name: body.fetch(:model_name),
                        model_publisher: body[:model_provider_name])]
          end

          def dedupe_by_model_id(entries:, **)
            seen = {}
            entries.select do |entry|
              id = entry[:deployment_name]
              unless id.is_a?(String) && !id.empty?
                raise InvalidCatalog, 'Azure deployment record requires deployment_name'
              end

              if seen.key?(id)
                raise InvalidCatalog, "conflicting Azure deployment records for #{id}" unless seen.fetch(id) == entry

                false
              else
                seen[id] = entry
                true
              end
            end
          end

          def context_window_for(entry:, **)
            positive_integer(value: entry[:context_window])
          end

          def positive_integer(value:, **)
            value = value.to_i if value.is_a?(String) && value.match?(/\A[0-9]+\z/)
            value if value.is_a?(Integer) && value.positive?
          end
        end
      end
    end
  end
end
