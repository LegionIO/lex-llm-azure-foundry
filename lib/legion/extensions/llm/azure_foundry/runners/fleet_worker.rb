# frozen_string_literal: true

require 'legion/llm/fleet/provider_responder'
require 'legion/extensions/llm/azure_foundry/provider'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Runners
          # Runner entrypoint for Azure Foundry fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::LLM::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: AzureFoundry::PROVIDER_FAMILY,
                provider_class: AzureFoundry::Provider,
                provider_instances: -> { AzureFoundry.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
