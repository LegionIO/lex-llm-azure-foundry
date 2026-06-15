# frozen_string_literal: true

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Style/Documentation
            include Legion::Logging::Helper

            REFRESH_INTERVAL = 1800

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return REFRESH_INTERVAL unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :azure_foundry, :discovery_interval) || REFRESH_INTERVAL
            end

            def manual
              log.debug('[azure_foundry][discovery_refresh] refreshing model list')
              return unless defined?(Legion::LLM::Discovery)

              Legion::LLM::Discovery.refresh_discovered_models!(provider: :azure_foundry)

              if defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:populate_auto_rules)
                Legion::LLM::Router.populate_auto_rules(Legion::LLM::Discovery.discovered_instances)
              end
              if defined?(Legion::LLM::Inventory) && Legion::LLM::Inventory.respond_to?(:invalidate_offerings_cache!)
                Legion::LLM::Inventory.invalidate_offerings_cache!
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'azure_foundry.actor.discovery_refresh')
            end
          end
        end
      end
    end
  end
end
