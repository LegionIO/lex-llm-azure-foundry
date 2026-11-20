# frozen_string_literal: true

require 'legion/extensions/llm/azure_foundry/model_catalog_parser'

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

            def build_quota_domains(model_id:)
              %i[chat stream_chat embed].to_h { |operation| [operation, "azure:deployment:#{model_id}"] }
            end

            def build_context_evidence(entry:, **)
              value = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.context_window_for(entry)
              value_evidence(value)
            end

            def build_max_output_evidence(entry:, **)
              value = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.positive_integer(
                entry[:max_output_tokens] || entry['max_output_tokens']
              )
              value_evidence(value)
            end

            def build_offering_metadata(model_id:, base_name:, instance_key:)
              family = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_family_for(base_name || model_id)
              {
                canonical_model_alias: base_name,
                model_family: family,
                instance_id: instance_key.instance_id,
                physical_id: instance_key.physical_id
              }.compact.freeze
            end

            def build_operation_evidence(entry:)
              evidence = %i[image transcribe translate speak moderate count_tokens].to_h do |operation|
                [operation, operation_evidence(operation, :unsupported, :provider_implementation)]
              end
              OPERATION_KEYS.each do |operation, keys|
                status = operation_status(entry, operation, keys)
                evidence[operation] = operation_evidence(operation, status, evidence_source(status))
              end
              stream_status = evidence[:chat].status
              stream_status = explicit_status(entry, [:streaming]) unless stream_status == :unsupported
              evidence[:stream_chat] = operation_evidence(:stream_chat, stream_status, evidence_source(stream_status))
              evidence
            end

            def operation_status(entry, operation, keys)
              status = explicit_status(entry, keys)
              return status unless status == :unknown

              type = entry[:model_type] || entry['model_type']
              return :unknown unless %w[chat-completion embeddings].include?(type)

              expected = operation == :embed ? 'embeddings' : 'chat-completion'
              type == expected ? :supported : :unsupported
            end

            def build_capability_evidence(entry:, operations:)
              CAPABILITY_KEYS.to_h do |capability, keys|
                status = explicit_status(entry, keys)
                status = operations[:embed].status if capability == :embedding
                status = operations[:chat].status if capability == :completion
                status = operations[:stream_chat].status if capability == :streaming
                [capability, Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                  capability: capability, status: status, source: evidence_source(status)
                )]
              end
            end

            def explicit_status(entry, keys)
              capabilities = entry[:capabilities] || entry['capabilities']
              return :unknown unless capabilities.is_a?(Hash)

              keys.each do |key|
                value = capabilities.key?(key) ? capabilities[key] : capabilities[key.to_s]
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

            def evidence_source(status) = status == :unknown ? :absent : :provider_catalog

            def value_evidence(value)
              return absent_value_evidence if value.nil?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: value,
                                                                    source: :provider_catalog)
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
