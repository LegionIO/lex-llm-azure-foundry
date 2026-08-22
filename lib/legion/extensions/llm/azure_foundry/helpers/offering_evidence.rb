# frozen_string_literal: true

require 'time'

require 'legion/extensions/llm/azure_foundry/model_catalog_parser'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # Capability and operation evidence builders for Azure Foundry
          # discovery — the immutable facts an OfferingDraft carries about
          # what a discovered model can and cannot do. Extended into
          # AzureFoundry::Runners::Discovery, whose build_offering_draft is
          # the sole consumer. All builders are private; extending a module
          # carries the visibility to the runner's module methods.
          module OfferingEvidence
            private

            # Embedding detection: an explicit catalog usage field when
            # present, otherwise the model name. A name match is a naming
            # hint, not authoritative proof.
            def embedding_model?(model_id, entry)
              usage = (entry['usage_type'] || entry[:usage_type] || entry['type'] || entry[:type]).to_s.downcase
              return true if %w[embed embedding].include?(usage)

              model_id.to_s.match?(/embed/i)
            end

            def build_context_evidence(entry:, instance_cfg:)
              ctx = Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.context_window_for(entry) ||
                    instance_cfg[:context_window] || instance_cfg[:max_input_tokens]
              return absent_value_evidence unless ctx.is_a?(Integer) && ctx.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known, value: ctx, source: :provider_catalog
              )
            end

            def build_max_output_evidence(entry:, instance_cfg:)
              max_out = entry['max_output_tokens'] || entry[:max_output_tokens] ||
                        instance_cfg[:max_output_tokens]
              return absent_value_evidence unless max_out.is_a?(Integer) && max_out.positive?

              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :known, value: max_out, source: :provider_catalog
              )
            end

            def build_quota_domains(model_id:)
              return {} if model_id.to_s.strip.empty?

              {
                chat: "azure:deployment:#{model_id}",
                stream_chat: "azure:deployment:#{model_id}",
                embed: "azure:deployment:#{model_id}"
              }
            end

            # Metadata is frozen and secret-free (07 R6): the raw catalog
            # entry is NOT embedded — its wire keys (max_output_tokens and
            # friends) collide with the secret-key token scan and would
            # break publication of any live catalog. The draft's evidence
            # members carry every authoritative value the entry reports.
            def build_offering_metadata(model_id:, base_name:, instance_key:)
              meta = {}
              meta[:canonical_model_alias] = base_name if base_name
              meta[:model_family] =
                Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.model_family_for(base_name || model_id)
              meta[:instance_id] = instance_key.instance_id
              meta[:physical_id] = instance_key.physical_id if instance_key.physical_id
              meta.compact
            end

            # An embedding deployment is authoritative evidence that chat is
            # NOT servable on it (matches bedrock's exclusion): publishing
            # chat :supported would let a plain chat request misroute to an
            # embedding-only deployment.
            def build_operation_evidence(embed_supported:)
              now = Time.now.freeze
              chat_status = embed_supported ? :unsupported : :supported
              embed_status = embed_supported ? :supported : :unsupported
              {
                chat: op_evidence(operation: :chat, status: chat_status, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: chat_status, observed_at: now),
                embed: op_evidence(operation: :embed, status: embed_status, observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unsupported, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(entry:, embed_supported:)
              evidence = base_capability_evidence
              unless embed_supported
                evidence[:tools] = cap_evidence(
                  capability: :tools, status: :supported, source: :provider_implementation
                )
                # Vision capability: model-name regex is not authoritative proof — stays :unknown.
                evidence[:vision] = cap_evidence(capability: :vision, status: :unknown, source: :default_false)
              end
              if embed_supported
                evidence[:embedding] = cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              end
              evidence[:thinking] = cap_evidence(
                capability: :thinking, status: :unknown,
                source: if entry.key?(:enable_thinking) || entry.key?('enable_thinking')
                          :instance_override
                        else
                          :default_false
                        end
              )
              evidence
            end

            def base_capability_evidence
              {
                completion: cap_evidence(capability: :completion, status: :supported, source: :provider_implementation),
                streaming: cap_evidence(capability: :streaming, status: :supported, source: :provider_implementation)
              }
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
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
