# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Parses the live model catalog returned by the Azure AI Foundry
        # inference surface's discovery endpoint. The SSOT v3 discovery
        # runner (Runners::Discovery#fetch_raw_models) parses the wire
        # response through this module — the single catalog parse path.
        #
        # Endpoint per surface (Provider#models_url / runner catalog_path):
        #   model_inference -> GET models/info?api-version=<api_version>
        #   openai_v1       -> GET models  (OpenAI-compatible shape)
        #
        # A dedicated model-inference /info response identifies its served
        # model with model_name and model_type. An OpenAI resource catalog
        # must instead identify deployments explicitly; base models alone
        # do not establish routable offerings. Malformed lists and conflicting
        # duplicate facts fail the refresh so the shared pipeline retains its
        # last complete snapshot.
        module ModelCatalogParser
          class InvalidCatalog < StandardError; end

          CATALOG_LIST_KEYS = %i[data models value models_list deployments].freeze
          # Deployment-unique identity keys, most-specific first. An Azure
          # Foundry *deployment* carries a unique id / deployment_name; the
          # base-model keys (model_name / model) are deliberately EXCLUDED —
          # multiple deployments of one base model share them, so resolving
          # the identity from them collapses two DISTINCT deployments onto one
          # provider_native_key and the registry Store#build_records raises
          # ValidationError: duplicate provider_native_key. The routable id is
          # the deployment, never the shared base model (bedrock's single
          # :model_id in spirit — one unambiguous key per offering).
          MODEL_ID_KEYS = %i[deployment_name id name].freeze
          BASE_NAME_KEYS = %i[model_name modelName base_model base_model_name].freeze
          CONTEXT_KEYS = %i[context_window max_input_tokens context_length].freeze
          # A catalog entry is model-shaped when it carries ANY recognized
          # model field — INCLUDING the base-model keys. Envelope recognition
          # (looks_like_model?) is deliberately broader than identity
          # resolution: a model-shaped entry that lacks a unique deployment id
          # is still recognized, then dropped by build_offerings' empty-id
          # filter rather than raising an unrecognized-envelope error.
          MODEL_SHAPE_KEYS = (MODEL_ID_KEYS + BASE_NAME_KEYS + %i[model]).uniq.freeze

          module_function

          # Extracts the raw model-entry list from a parsed catalog response
          # body. Raises on an unrecognized envelope.
          def model_entries(body:, surface: nil, **)
            entries = extract_entries(body)
            unless entries.is_a?(Array) && entries.all?(Hash)
              raise InvalidCatalog, 'Azure catalog must contain an array of model records'
            end

            if surface == :model_inference
              entries = entries.map { |entry| normalize_model_info(entry) }
            elsif surface == :openai_v1
              validate_deployment_identities(entries: entries)
            end
            dedupe_by_model_id(entries)
          end

          def validate_deployment_identities(entries:, **)
            return if entries.all? { |entry| lookup(entry, [:deployment_name]) }

            raise InvalidCatalog, 'Azure model catalog is not a deployment inventory; configure ' \
                                  'provider.project_endpoint and credentials.project_bearer_token'
          end

          def normalize_model_info(entry)
            return entry if model_id_for(entry)
            return entry unless %w[chat-completion embeddings].include?(lookup(entry, [:model_type]))

            name = lookup(entry, [:model_name])
            name ? entry.merge(id: name) : entry
          end

          # The Azure-served OpenAI catalog reports some model ids more than
          # once (near-identical entries — observed duplicates differ only in
          # created_at). Identity IS the resolved model id, and the registry
          # Store#build_records raises ValidationError: duplicate
          # provider_native_key on repeats — so collapse each resolved id to
          # its first occurrence. Entries without a resolvable id pass
          # through untouched for build_offerings' empty-id filter.
          def dedupe_by_model_id(entries)
            seen = {}
            entries.select do |entry|
              id = model_id_for(entry)
              next true if id.nil?

              if seen.key?(id)
                previous = seen.fetch(id).transform_keys(&:to_sym).except(:created, :created_at)
                current = entry.transform_keys(&:to_sym).except(:created, :created_at)
                unless previous == current
                  raise InvalidCatalog,
                        "conflicting Azure catalog records for deployment #{id}"
                end

                false
              else
                seen[id] = entry
                true
              end
            end
          end

          def extract_entries(body)
            return body if body.is_a?(Array)
            raise InvalidCatalog, "Azure Foundry catalog response must be a Hash or Array, got #{body.class}" unless
              body.is_a?(Hash)

            key = list_key_for(body)
            return body[key] || body[key.to_s] if key
            return [body] if looks_like_model?(body)

            raise InvalidCatalog, 'unrecognized Azure Foundry catalog envelope'
          end

          def list_key_for(body)
            CATALOG_LIST_KEYS.find { |k| body.key?(k) || body.key?(k.to_s) }
          end

          def looks_like_model?(body) = MODEL_SHAPE_KEYS.any? { |k| body.key?(k) || body.key?(k.to_s) }

          # Resolves the routable, unique-per-deployment identity for a raw
          # catalog entry. On the Foundry surface this is the deployment name
          # (what the API accepts as the model field); on the OpenAI surface
          # it is the model id. Never the shared base model — that collapses
          # two distinct deployments onto one provider_native_key.
          def model_id_for(entry) = lookup(entry, MODEL_ID_KEYS)&.to_s

          # The base/underlying model name, when the catalog reports one
          # distinct from the routable id (e.g. Foundry model_name).
          def base_model_name_for(entry) = lookup(entry, BASE_NAME_KEYS)&.to_s

          def context_window_for(entry)
            CONTEXT_KEYS.each do |key|
              value = entry[key] || entry[key.to_s]
              parsed = positive_integer(value)
              return parsed if parsed
            end
            nil
          end

          def positive_integer(value)
            value = value.to_i if value.is_a?(String) && value.match?(/\A[0-9]+\z/)
            value if value.is_a?(Integer) && value.positive?
          end

          # Infers the model family from a model name. Name inference is a
          # metadata hint only, never authoritative capability evidence.
          def model_family_for(name)
            id = name.to_s.downcase
            return :openai if id.match?(/gpt|o\d|text-embedding|dall-e/)
            return :mistral if id.include?('mistral')
            return :meta if id.match?(/llama|meta/)
            return :xai if id.match?(/grok|xai/)
            return :anthropic if id.include?('claude')
            return :microsoft if id.match?(/phi|microsoft/)

            nil
          end

          def lookup(entry, keys)
            keys.each do |key|
              value = entry[key] || entry[key.to_s]
              return value if value.is_a?(String) && !value.strip.empty?
            end
            nil
          end
        end
      end
    end
  end
end
