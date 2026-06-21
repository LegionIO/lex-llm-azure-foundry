# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Style/Documentation,Metrics/ClassLength
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            EMBED_TYPES = %i[embed embedding].freeze

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return self.class.every_seconds unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :azure_foundry, :discovery_interval) || self.class.every_seconds
            end

            def manual # rubocop:disable Metrics/CyclomaticComplexity
              log.debug('[azure_foundry][discovery_refresh] refreshing model list')
              tick if respond_to?(:tick)

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

            def scope_key(**)
              { provider: :azure_foundry }
            end

            def compute_lanes_for_scope(**)
              return [] unless defined?(Legion::LLM::Call::Registry)

              instances = Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :azure_foundry
              end

              lanes = []
              instances.each { |entry| collect_instance_lanes(entry, lanes) }
              lanes
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'azure_foundry.compute_lanes_for_scope')
              []
            end

            def credential_hash(**)
              settings = Legion::Settings.dig(:extensions, :llm, :azure_foundry) || {}
              ::Digest::SHA256.hexdigest(settings[:api_key].to_s + settings[:instances].to_s)[0, 16]
            rescue StandardError
              'unknown'
            end

            private

            def collect_instance_lanes(instance_entry, lanes)
              adapter = instance_entry[:adapter]
              return unless adapter.respond_to?(:discover_offerings)

              Array(adapter.discover_offerings(live: true)).each do |offering|
                build_and_append_lanes(offering, instance_entry, lanes)
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'azure_foundry.compute_lanes_for_scope.instance')
            end

            def build_and_append_lanes(offering, instance_entry, lanes)
              raw = offering.respond_to?(:to_h) ? offering.to_h : offering
              return unless raw.is_a?(Hash)

              lane = build_lane(raw, instance_entry)
              lanes << lane
              lanes << lane.merge(id: fleet_id_for(lane), tier: :fleet) if fleet_enabled? && lane[:type] == :inference
            end

            def build_lane(raw, instance_entry) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
              model       = raw[:model] || raw['model']
              instance_id = raw[:instance_id] || raw['instance_id'] ||
                            instance_entry[:instance] || instance_entry[:instance_id] ||
                            instance_entry[:id] || :default
              pf          = raw[:provider_family] || raw['provider_family'] || :azure_foundry
              type        = resolve_type(raw)
              tier        = (raw[:tier] || raw['tier'] || :cloud).to_sym
              lane_id     = compose_lane_id(tier: tier, provider_family: pf, instance_id: instance_id,
                                            type: type, model: model)

              {
                id: lane_id,
                tier: tier,
                provider_family: pf,
                instance_id: instance_id,
                model: model,
                canonical_model_alias: raw[:canonical_model_alias] || raw['canonical_model_alias'],
                type: type,
                capabilities: normalize_capabilities(raw[:capabilities] || raw['capabilities'] || []),
                limits: raw[:limits] || raw['limits'] || {},
                enabled: raw.fetch(:enabled, raw.fetch('enabled', true)),
                cost: raw[:cost] || raw['cost'] || {}
              }
            end

            def resolve_type(raw)
              val = raw[:type] || raw['type'] || raw[:usage_type] || raw['usage_type']
              EMBED_TYPES.include?(val&.to_sym) ? :embedding : :inference
            end

            def normalize_capabilities(raw)
              if defined?(Legion::Extensions::Llm::Inventory::Capabilities)
                Legion::Extensions::Llm::Inventory::Capabilities.normalize(raw)
              else
                Array(raw)
              end
            end

            def compose_lane_id(**fields)
              Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(fields)
            end

            def fleet_id_for(lane)
              compose_lane_id(tier: :fleet, provider_family: lane[:provider_family],
                              instance_id: lane[:instance_id], type: lane[:type], model: lane[:model])
            end

            def fleet_enabled?
              settings = Legion::Settings.dig(:extensions, :llm, :azure_foundry) || {}
              settings[:fleet]&.dig(:dispatch, :enabled)
            end
          end
        end
      end
    end
  end
end
