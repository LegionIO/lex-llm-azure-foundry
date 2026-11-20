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

          attr_reader :surface

          def initialize(endpoint:, surface:, api_version:)
            @surface = surface.to_sym
            raise ArgumentError, 'unsupported Azure Foundry surface' unless %i[model_inference
                                                                               openai_v1].include?(@surface)

            @uri = URI.parse(endpoint.to_s)
            unless %w[http https].include?(@uri.scheme) && @uri.host && !@uri.query && !@uri.fragment && !@uri.userinfo
              raise ArgumentError,
                    'Azure Foundry endpoint must be an absolute HTTP URL without credentials, query, or fragment'
            end

            @api_version = api_version
          end

          def base_url
            url = @uri.to_s.sub(%r{/+\z}, '')
            return url.delete_suffix('/models') if surface == :model_inference
            return url if url.end_with?('/openai/v1')

            "#{url}/openai/v1"
          end

          def path(operation:)
            return operation if surface == :openai_v1

            "models/#{operation}?#{URI.encode_www_form('api-version' => @api_version)}"
          end

          def catalog_path = path(operation: surface == :model_inference ? 'info' : 'models')
        end
      end
    end
  end
end
