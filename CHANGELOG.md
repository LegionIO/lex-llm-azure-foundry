# Changelog

## [0.2.15] - 2026-07-09

### Fixed
- Offerings now populate `limits[:context_window]` (and `max_output_tokens`), so the router sees real capacity for Azure lanes instead of nil/unbounded. `build_offering` previously never set `limits` — deployment config context sizes landed in `metadata` and were invisible to routing (a request could then mis-route to an Azure lane the router thought had unlimited context). `context_window` is sourced from live catalog when the endpoint reports it, else per-deployment instance config (`context_window`/`max_input_tokens`), else nil (a genuine per-instance gap — never a hardcoded guess). Azure's inference-plane endpoints (`model_inference GET /info`, `openai_v1 GET /models`) do not report per-model context length, mirroring the OpenAI/Bedrock cloud providers. `Model::Info#context_length` (models API) is populated the same way.

## [0.2.14] - 2026-07-03

### Fixed
- Emit relative request paths from `path_for` (no leading slash). `Connection` builds Faraday with `api_base` as the base URL; on the `openai_v1` surface that base carries the `/openai/v1` path, and a leading-slash path was treated as absolute and dropped it — 404ing live discovery (empty offerings) and chat. Paths are now relative so the base path survives on both surfaces.
- Resolve `models_url`/`health_url` per surface: `models` on `openai_v1`, `models/info` on `model_inference`. Previously always `info`, which 404s on the `openai_v1` surface.

## [0.2.13] - 2026-06-20

### Fixed
- Stub shared registry publishing through `RegistryPublisher#schedule` in specs so async availability-event coverage stays stable after the shared publisher moved off raw `Thread.new`.

## [0.2.12] - 2026-06-20

### Changed
- Align Azure Foundry instance discovery with the shared `lex-llm` contract by preserving explicit tier overrides while defaulting unconfigured instances to `:cloud`.
- Restore offline deployment-backed offering discovery and carry the configured provider instance id through Azure offering metadata.
- Normalize Azure Foundry capability and health metadata to the current shared offering contract.

## [0.2.11] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.2.10 - 2026-06-16

- Dependency updates and code quality improvements.

## 0.2.9 - 2026-06-15

- **CapabilityPolicy integration** — Streaming from `:provider_envelope`; deployment metadata as `:model_metadata`. Settings overrides at provider/instance/model level supported.

## 0.2.8 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Dependency bump** — Require `lex-llm >= 0.5.0` for canonical types support.
- **Capabilities** — Add canonical `:tools` to capability declarations.
- 26 examples, 0 failures; 13 files, 0 rubocop offenses.

## 0.2.7 - 2026-06-02

- Add per-provider scoped discovery refresh actor

## 0.2.6 - 2026-05-21

- Add `default_transport`/`default_tier` class declarations, remove `configured_transport`/`configured_tier`
- Add `model_allowed?` filtering in `discover_offerings`
- Default tier set to :cloud
- Identity headers included via base provider


## 0.2.5 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical Azure Foundry provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Preserve configured transport and tier metadata when Azure Foundry builds routing offerings.
- Gate release publishing on the shared security workflow.

## 0.2.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.2.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.2.2 - 2026-05-06

- Enforce the shared keyword-only `lex-llm` provider contract for chat, embeddings, and token counting.
- Move defaults back to `Legion::Extensions::Llm.provider_settings` with credentials/provider metadata under the default instance and instance-level fleet responder settings.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.2.1 - 2026-05-03

- Normalize generic settings keys to Azure Foundry provider config keys during instance discovery.

## 0.2.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## [0.1.6] - 2026-05-01

- Require lex-llm >= 0.1.9 for the shared base contract
- Replace local RegistryPublisher and RegistryEventBuilder with base classes from lex-llm
- Delete local transport/ directory (exchange and message classes now live in lex-llm)
- Remove deprecated Provider.register call; use Configuration.register_provider_options directly
- Simplify default_settings to flat provider hash (no provider_settings builder)
- Fix Model::Info construction to use modalities_input/modalities_output keywords

## [0.1.5] - 2026-04-30

- Audit all rescue blocks for handle_exception compliance across Provider, RegistryPublisher, and RegistryEventBuilder
- Add Legion::Logging::Helper to AzureFoundry module, RegistryPublisher, and RegistryEventBuilder
- Add info-level action logging for discover_offerings, health, readiness, list_models, chat, stream, embed, and registry publish
- Remove custom log_publish_failure in favour of standard handle_exception
- Update README to reflect current architecture, file map, and observability

## [0.1.4] - 2026-04-30

- Enable stream_usage_supported? for streaming token usage reporting

## 0.1.3 - 2026-04-28

- Remove the unused runtime `legion/settings` require while preserving the gemspec dependency.

## 0.1.2 - 2026-04-28

- Publish best-effort `llm.registry` live readiness and configured deployment model availability events using `lex-llm` registry envelopes when transport is already available.

## 0.1.1 - 2026-04-28

- Require `lex-llm >= 0.1.5` for the shared model offering, canonical alias, readiness, and fleet lane contract used by Azure deployment routing metadata.

## 0.1.0 - 2026-04-28

- Initial Legion LLM Azure AI Foundry provider extension scaffold.
- Add Azure AI Foundry model inference and Azure OpenAI v1-compatible endpoint mapping.
- Add offline deployment-based offering discovery with explicit model-family and canonical-alias metadata.
- Add chat, streaming, embeddings, health, and token-count placeholder provider methods without requiring live Azure access.
