# frozen_string_literal: true

# The LegionIO daemon provides the actor runtime (Every/Subscription) and the
# extension helpers (Lex). Specs run against the lex gems only, so stub the
# minimal surface the actor files need to load. spec_helper requires this file
# before any lex-llm-azure-foundry require; each stub is a no-op when the real
# constant already exists.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Test stand-in for Legion::Extensions::Actors::Every. Instances are
        # driven directly via #manual / #shutdown in specs; no timer is
        # started.
        class Every
          def initialize(**)
            # Intentionally timer-free.
          end
        end
      end
    end

    module Helpers
      unless const_defined?(:Lex, false)
        # Test stand-in for Legion::Extensions::Helpers::Lex: an isolated,
        # mutable per-instance settings hash (mirrors the production helper's
        # dig-or-create shape for the levels the actor touches).
        module Lex
          def settings
            @settings ||= {}
          end
        end
      end
    end
  end
end
