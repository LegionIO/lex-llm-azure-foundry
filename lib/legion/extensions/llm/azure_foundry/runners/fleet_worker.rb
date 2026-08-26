# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/azure_foundry'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Runners
          # Runner entrypoint for Azure Foundry fleet request execution.
          #
          # The Subscription dispatch path invokes this as
          # runner_class.send(fn, **message) where message is the fleet
          # request envelope merged with transport metadata (routing_key,
          # message_id, headers, ...). The responder parses the envelope out
          # of that hash; unknown keys are inert. Errors propagate to the
          # Subscription's rescue (logged + retry-or-DLQ) — never swallowed.
          module FleetWorker
            module_function

            def handle_fleet_request(**opts)
              # L6: the responder's dead provider_class/provider_instances
              # params are gone from the 0.8.0 core — v3 dispatch is
              # exact-only and never constructs a provider here.
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: opts,
                provider_family: AzureFoundry::PROVIDER_FAMILY,
                delivery: opts[:delivery],
                properties: opts[:properties]
              )
            end
          end
        end
      end
    end
  end
end
