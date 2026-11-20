# frozen_string_literal: true

require 'uri'
require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Protocol URL construction shared by discovery and inference.
        class Endpoint
          include Legion::Logging::Helper

          attr_reader :surface, :api_version

          def initialize(endpoint:, surface:, api_version:, **)
            @surface = normalize_surface(value: surface)
            @uri = URI.parse(endpoint.to_s)
            @api_version = api_version
            validate_endpoint!
            validate_version!
          end

          def base_url
            url = @uri.to_s.sub(%r{/+\z}, '')
            return url.delete_suffix('/models') if surface == :model_inference
            return url if url.end_with?('/openai/v1')

            "#{url}/openai/v1"
          end

          def path(operation:, **)
            return operation if surface == :openai_v1

            "models/#{operation}?#{URI.encode_www_form('api-version' => @api_version)}"
          end

          def catalog_path = path(operation: surface == :model_inference ? 'info' : 'models')

          private

          def normalize_surface(value:)
            unless value.is_a?(String) || value.is_a?(Symbol)
              raise ArgumentError, 'Azure Foundry surface must be explicit'
            end

            normalized = value.to_sym
            return normalized if %i[model_inference openai_v1].include?(normalized)

            raise ArgumentError, 'unsupported Azure Foundry surface'
          end

          def validate_endpoint!
            return if %w[http
                         https].include?(@uri.scheme) && @uri.host && !@uri.query && !@uri.fragment && !@uri.userinfo

            raise ArgumentError,
                  'Azure Foundry endpoint must be an absolute HTTP URL without credentials, query, or fragment'
          end

          def validate_version!
            return unless surface == :model_inference && (!api_version.is_a?(String) || api_version.empty?)

            raise ArgumentError, 'Azure model-inference API version must be explicit'
          end
        end
      end
    end
  end
end
