# frozen_string_literal: true

require 'legion/extensions/llm/azure_foundry'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/azure_foundry/runners/fleet_worker'
require 'legion/extensions/actors/subscription'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Actor
          # Subscription actor for Azure Foundry fleet request consumption.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            # The Subscription dispatch path (use_runner? == false) calls
            # runner_class.send(fn, **message) — a String cannot be send-ed, so
            # the runner must be the resolved module constant, and the runner's
            # entry point must accept the decoded message as keyword arguments.
            def runner_class
              Legion::Extensions::Llm::AzureFoundry::Runners::FleetWorker
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(
                Legion::Extensions::Llm::AzureFoundry.discover_instances
              )
            end
          end
        end
      end
    end
  end
end
