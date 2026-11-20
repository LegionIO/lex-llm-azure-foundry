# frozen_string_literal: true

require 'legion/extensions/llm/error'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        # Static credentials are explicit; broker references select host-owned
        # leases. The provider never caches tokens or creates a renewal loop.
        module Authentication
          module_function

          def configured?(api_key: nil, bearer_token: nil, broker: nil, **)
            !source_kind(api_key: api_key, bearer_token: bearer_token, broker: broker).nil?
          end

          def headers(purpose:, api_key: nil, bearer_token: nil, broker: nil, **)
            case source_kind(api_key: api_key, bearer_token: bearer_token, broker: broker)
            when :api_key then { 'api-key' => api_key }
            when :bearer_token then { 'Authorization' => "Bearer #{bearer_token}" }
            when :broker then { 'Authorization' => "Bearer #{broker_token(broker: broker, purpose: purpose)}" }
            else raise Legion::Extensions::Llm::ConfigurationError, 'An Azure credential source is required'
            end
          end

          def install_discovery(faraday:, api_key: nil, bearer_token: nil, broker: nil, **)
            if source_kind(api_key: api_key, bearer_token: bearer_token, broker: broker) == :broker
              descriptor = reference(broker: broker)
              faraday.request(:authorization, 'Bearer', -> { broker_token(broker: descriptor, purpose: :discovery) })
            else
              faraday.headers.merge!(headers(api_key: api_key, bearer_token: bearer_token, purpose: :discovery))
            end
          end

          def broker_token(broker:, purpose:, **)
            descriptor = reference(broker: broker)
            # Broker is an optional host-runtime integration. Static provider
            # use does not load LegionIO. Broker mode requires the real service.
            require 'legion/identity/broker'
            token = Legion::Identity::Broker.token_for(
              descriptor.fetch(:provider), qualifier: descriptor.fetch(:qualifier),
                                           purpose: "llm.azure_foundry.#{purpose}"
            )
            unless credential?(token)
              raise Legion::Extensions::Llm::UnauthorizedError,
                    'No current Azure broker credential for the configured qualifier'
            end

            token
          rescue LoadError => e
            raise Legion::Extensions::Llm::ConfigurationError,
                  'Azure broker authentication requires the LegionIO identity runtime', cause: e
          end

          def reference(broker:, **)
            return nil if broker.nil?
            unless broker.is_a?(Hash)
              raise Legion::Extensions::Llm::ConfigurationError,
                    'Azure broker reference must contain provider and qualifier'
            end

            provider = broker[:provider]
            qualifier = broker[:qualifier]
            unless reference_name?(provider) && reference_name?(qualifier)
              raise Legion::Extensions::Llm::ConfigurationError, 'Azure broker provider and qualifier must be explicit'
            end

            { provider: provider.to_sym, qualifier: qualifier.to_sym }.freeze
          end

          def reference_name?(value) = (value.is_a?(String) || value.is_a?(Symbol)) && !value.to_s.strip.empty?
          def credential?(value) = value.is_a?(String) && !value.strip.empty?

          def source_kind(api_key:, bearer_token:, broker:)
            validate_static_credentials!(api_key: api_key, bearer_token: bearer_token)
            selected = []
            selected << :api_key if credential?(api_key)
            selected << :bearer_token if credential?(bearer_token)
            selected << :broker if reference(broker: broker)
            if selected.size > 1
              raise Legion::Extensions::Llm::ConfigurationError,
                    'Configure exactly one Azure credential source per scope'
            end

            selected.first
          end

          def validate_static_credentials!(api_key:, bearer_token:)
            [api_key, bearer_token].each do |value|
              unless value.nil? || value.is_a?(String)
                raise Legion::Extensions::Llm::ConfigurationError, 'Azure static credentials must be strings'
              end
            end
          end
          private_class_method :reference_name?, :credential?, :source_kind, :validate_static_credentials!
        end
      end
    end
  end
end
