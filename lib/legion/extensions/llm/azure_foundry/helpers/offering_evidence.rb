# frozen_string_literal: true

require 'legion/extensions/llm/azure_foundry/model_catalog_parser'
require 'legion/extensions/llm/azure_foundry/provider'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # Translate Azure facts into canonical evidence. A model name,
          # operator permission, or catalog GET proves no capability.
          module OfferingEvidence
            OPERATION_KEYS = { chat: %i[chat_completion chatCompletion], embed: %i[embeddings embedding] }.freeze
            CAPABILITY_KEYS = {
              tools: %i[function_calling tools], vision: %i[vision], thinking: %i[reasoning thinking],
              streaming: %i[streaming], completion: %i[chat_completion chatCompletion],
              embedding: %i[embeddings embedding]
            }.freeze

            private

            def build_context_evidence(entry:, **) = limit_evidence(entry: entry, key: :context_window)
            def build_max_output_evidence(entry:, **) = limit_evidence(entry: entry, key: :max_output_tokens)

            def build_operation_evidence(entry:)
              evidence = %i[image transcribe translate speak moderate count_tokens].to_h do |operation|
                [operation, operation_evidence(operation, :unsupported, :provider_implementation)]
              end
              OPERATION_KEYS.each do |operation, keys|
                fact = operation_fact(entry: entry, operation: operation, keys: keys)
                evidence[operation] = operation_evidence(operation, *fact)
              end
              chat = evidence.fetch(:chat)
              stream_fact = if chat.unsupported?
                              [chat.status, chat.source]
                            else
                              capability_fact(entry: entry, capability: :streaming, keys: [:streaming])
                            end
              evidence[:stream_chat] = operation_evidence(:stream_chat, *stream_fact)
              evidence
            end

            def operation_fact(entry:, operation:, keys:)
              status = operation_status(entry, operation, keys)
              return [status, :provider_catalog] unless status == :unknown

              metadata_capability_fact(entry: entry, capability: operation == :chat ? :completion : :embedding)
            end

            def operation_status(entry, operation, keys)
              status = explicit_status(entry, keys)
              return status unless status == :unknown

              type = entry[:model_type]
              return :unknown unless %w[chat-completion embeddings].include?(type)

              expected = operation == :embed ? 'embeddings' : 'chat-completion'
              type == expected ? :supported : :unsupported
            end

            def build_capability_evidence(entry:, operations:)
              operation_map = { embedding: :embed, completion: :chat, streaming: :stream_chat }
              CAPABILITY_KEYS.to_h do |capability, keys|
                operation = operation_map[capability]
                status, source = if operation
                                   fact = operations.fetch(operation)
                                   [fact.status, fact.source]
                                 else
                                   capability_fact(entry: entry, capability: capability, keys: keys)
                                 end
                [capability, Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                  capability: capability, status: status, source: source
                )]
              end
            end

            def explicit_status(entry, keys)
              capabilities = entry[:capabilities]
              return :unknown unless capabilities.is_a?(Hash)

              keys.each do |key|
                value = capabilities[key]
                return :supported if [true, 'true'].include?(value)
                return :unsupported if [false, 'false'].include?(value)
              end
              :unknown
            end

            def operation_evidence(operation, status, source)
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source
              )
            end

            def capability_fact(entry:, capability:, keys:)
              status = explicit_status(entry, keys)
              return [status, :provider_catalog] unless status == :unknown

              metadata_capability_fact(entry: entry, capability: capability)
            end

            def metadata_capability_fact(entry:, capability:)
              value = model_metadata(entry: entry)&.dig(:capabilities, capability)
              return %i[supported model_metadata] if value == true
              return %i[unsupported model_metadata] if value == false

              %i[unknown absent]
            end

            def limit_evidence(entry:, key:)
              catalog_value = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.positive_integer(
                value: entry[key]
              )
              return value_evidence(catalog_value) unless catalog_value.nil?

              value_evidence(model_metadata(entry: entry)&.[](key), source: :model_metadata)
            end

            def model_metadata(entry:)
              Legion::Extensions::Llm::AzureFoundry::Provider::MODEL_METADATA[entry[:model_metadata_key]]
            end

            def value_evidence(value, source: :provider_catalog)
              return absent_value_evidence if value.nil?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value,
                                                                    source: source)
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end
        end
      end
    end
  end
end
