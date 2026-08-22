# frozen_string_literal: true

# The LegionIO daemon provides the actor runtime (Every) and the extension
# helper (Lex). Specs run against the lex gems only, so stub the minimal
# surface the gem's actor/runner files need to load. spec_helper requires this
# file before any lex-llm-azure-foundry require; each stub is a no-op when the
# real constant already exists.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Test stand-in for Legion::Extensions::Actors::Every. The shared
        # discovery actor base subclasses it; no timer is started in specs.
        class Every
          def initialize(**)
            # Intentionally timer-free.
          end
        end
      end
    end

    module Helpers
      unless const_defined?(:Lex, false)
        # Functional stand-in for the LegionIO `Legion::Extensions::Helpers::Lex`
        # helper, for Azure Foundry specs. Provides the REAL
        # settings/log/handle_exception the provider runner relies on (the
        # shared Discovery::Pipeline's error paths call log/handle_exception on
        # the runner module; its D14 health write-back reads `settings`),
        # without loading the full LegionIO helper stack.
        #
        # `settings` comes from Legion::Settings::Helper (legion-settings),
        # which derives the nested extension path from the caller's namespace —
        # Runners::*/Actor::* stop at NAMESPACE_BOUNDARIES, so the discovery
        # runner resolves to Legion::Settings[:extensions][:llm][:azure_foundry]
        # and is writable: specs drive D14 health writes through the genuine
        # settings tree. `log`/`handle_exception` come from
        # Legion::Logging::Helper (handle_exception logs, never re-raises).
        #
        # The self-extend hook mirrors the real Lex so module-level runners get
        # settings/log/handle_exception on the module.
        module Lex
          include Legion::Logging::Helper
          include Legion::Settings::Helper

          def self.included(base)
            base.extend(base) if base.instance_of?(Module) && !base.instance_of?(Class)
          end
        end
      end
    end
  end
end
