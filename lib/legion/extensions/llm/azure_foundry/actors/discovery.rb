# frozen_string_literal: true

require 'legion/extensions/llm/discovery/actor'

# The base discovery actor only exists inside the daemon (it inherits the
# LegionIO time-based Every actor). In a standalone load, define nothing.
return unless defined?(Legion::Extensions::Llm::Discovery::Actor)

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Actor
          # Azure Foundry discovery actor: an EMPTY subclass of the shared
          # base. The timer, dispatch, and runner-resolution convention are
          # inherited — this class redefines nothing. The Azure Foundry-
          # specific work lives in AzureFoundry::Runners::Discovery, resolved
          # by the base from this namespace.
          class Discovery < Legion::Extensions::Llm::Discovery::Actor; end
        end
      end
    end
  end
end
