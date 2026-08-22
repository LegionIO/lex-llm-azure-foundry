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
        # The model_inference envelope is parsed defensively: a list under
        # data / models / value / deployments (or a bare array) yields that
        # list; a single model object (no list key, but carrying a model
        # identity) yields a one-element catalog. A body that is neither an
        # array, a recognizable list, nor a recognizable model object raises
        # — a silent empty catalog is exactly how the old config-only
        # discovery hid from every consumer. No captured fixture of the
        # model_inference envelope exists in the monorepo, so live
        # confirmation of the wire shape is still required (see PR).
        module ModelCatalogParser
          CATALOG_LIST_KEYS = %i[data models value models_list deployments].freeze
          MODEL_ID_KEYS = %i[id name model_name deployment_name model].freeze
          BASE_NAME_KEYS = %i[model_name base_model base_model_name].freeze
          CONTEXT_KEYS = %i[context_window max_input_tokens context_length].freeze

          module_function

          # Extracts the raw model-entry list from a parsed catalog response
          # body. Raises on an unrecognized envelope.
          def model_entries(body)
            Array(extract_entries(body)).grep(Hash)
          end

          def extract_entries(body)
            return body if body.is_a?(Array)
            raise ArgumentError, "Azure Foundry catalog response must be a Hash or Array, got #{body.class}" unless
              body.is_a?(Hash)

            key = list_key_for(body)
            return body[key] || body[key.to_s] if key
            return [body] if looks_like_model?(body)

            raise ArgumentError, "unrecognized Azure Foundry catalog envelope: #{body.keys.first(5).inspect}"
          end

          def list_key_for(body)
            CATALOG_LIST_KEYS.find { |k| body.key?(k) || body.key?(k.to_s) }
          end

          def looks_like_model?(body) = MODEL_ID_KEYS.any? { |k| body.key?(k) || body.key?(k.to_s) }

          # Resolves the routable model identity for a raw catalog entry. On
          # the Foundry surface this is the deployment name (what the API
          # accepts as the model field); on the OpenAI surface it is the
          # model id.
          def model_id_for(entry) = lookup(entry, MODEL_ID_KEYS)&.to_s

          # The base/underlying model name, when the catalog reports one
          # distinct from the routable id (e.g. Foundry model_name).
          def base_model_name_for(entry) = lookup(entry, BASE_NAME_KEYS)&.to_s

          def context_window_for(entry)
            CONTEXT_KEYS.each do |key|
              value = entry[key] || entry[key.to_s]
              next unless value.is_a?(String) || value.is_a?(Numeric)

              return value.to_i
            end
            nil
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
