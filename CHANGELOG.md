# Changelog

## [0.4.0] - 2026-08-19

### Changed
- **Live model catalog discovery — standard lex-llm interface.**
  `list_models` and `discover_offerings` now fetch the model catalog from
  the instance's discovery endpoint (`GET models/info?api-version=...` on the
  model-inference surface, `GET /models` on the OpenAI-compatible surface)
  and derive offerings through the shared base-class flow — the same
  endpoint-driven discovery every other provider uses. Offerings are
  published with `publication_source: :provider_catalog`.
- **Shared `ModelCatalogParser`.** Both the Provider's `list_models` and the
  SSOT v3 `DiscoveryRefresh` actor parse the wire catalog through one module
  (envelope: `data` / `models` / `value` / `deployments` list keys, bare
  arrays, or a single model object). An unrecognized envelope raises instead
  of producing a silent empty catalog.
- **Discovery actor fetches the live catalog.** `discover_offerings_for_instance`
  hits the same endpoint (and auth) as the readiness probe and builds one
  OfferingDraft per catalog entry. A failed fetch yields nil so the refresh
  loop keeps the last complete snapshot rather than deleting it.

### Removed
- **Configured deployments — the static discovery path is gone.**
  `azure_foundry_deployments` (and the `deployments` / `provider.deployments`
  settings aliases) no longer exist. `ProviderClassMethods#resolve_model_id`,
  `#deployment_config`, `#normalize_deployments`, and the config-driven
  offering path (`allowed_offerings` / `configured_deployments` /
  `offering_from_config`) are deleted. The model set is whatever the endpoint
  reports — nothing about models lives in settings.
- `provider_native_key` and `model` are both the catalog model id (the
  routable id the endpoint accepts); the base model name rides along as
  `canonical_model_alias` when the catalog reports one.

### Fixed
- **Bearer-token auth on the actor path.** `apply_auth_headers` now sends
  `Authorization: Bearer` when the instance carries a bearer token
  (previously api-key only — bearer-only instances failed the readiness
  probe and stayed `:initializing` forever).

### Notes
- No captured fixture of the model-inference `models/info` list envelope
  exists in the monorepo. The parser accepts the known shapes; live
  confirmation of the wire response against a real project is the one
  remaining UAT item for this change.

## [0.3.5] - 2026-08-19

### Changed
- **Write-time SSOT lane weights** — Build Azure deployment drafts with the shared
  four-component weight pair using the deployment name as the provider-native
  offering identity, and reconcile weight-only changes atomically on the existing
  discovery cadence. Initial/recovery activation now rebuilds from current settings,
  removal wins readiness races, and dormant configured weights log once per absence
  period without any Settings lifecycle callback.
- **Callable-path system conformance** — Capture the rendered Azure/OpenAI-compatible
  HTTP payload and verify a folded leading system message remains in the dialect-native
  `role: system` message position.
- **Dependency floor** — Raise `lex-llm` to `>= 0.7.6` for `WeightSchema`,
  `WeightReconciler`, and the immutable record weight pair. The `legion-settings`
  dependency and provider/operator workflow are unchanged.

### Fixed
- **Malformed-weight startup cleanup** — Validate and build weighted offering
  drafts before constructing or claiming any callable scope, so invalid weight
  values cannot leave an orphaned initializing Registry publication. A later
  corrected discovery pass claims and activates the instance normally without
  requiring a restart or operator cleanup.
- **Complete offering replacement comparison** — Ordinary discovery now compares
  every authoritative `OfferingDraft` field while ignoring only evidence
  observation timestamps. Deployment order does not churn, duplicate counts stay
  significant, and native-key, evidence, quota, metadata, publication-source,
  tier, or weight drift advances the Registry snapshot exactly once.

## [0.3.4] - 2026-08-18

### Fixed
- **Default instance labels** — Accept `default` as an ordinary operator
  `InstanceKey` label, matching the shared `lex-llm` identity contract.

## [0.3.3] - 2026-08-16

### Changed
- **Instance identity is the operator's config name** — the discovery actor now
  publishes `InstanceKey.instance_id` as the config NAME (the key the router
  resolves `instances.<name>` settings — per-instance tuning, `enable_*`
  overrides — by), restoring the baseline semantics. The previously-derived
  `host:port[/ak:fingerprint]` id is kept as the **secondary** `InstanceKey`
  `physical_id` field (dedup/diagnostics only; it never participates in
  equality, hashing, or registry-scope identity). Two config names pointing at
  the same endpoint stay distinct instances; the credential fingerprint still
  distinguishes same-name configs in diagnostics. `physical_id` is threaded
  through every `Inventory::Publisher` lifecycle call and onto offering
  metadata.
- **Authoritative operation evidence for embedding deployments** — an embedding
  deployment now publishes `chat: :unsupported` and `stream_chat: :unsupported`
  (with `embed: :supported`), matching how bedrock authoritatively excludes
  embedding models, so a plain chat request can no longer misroute to an
  embedding-only deployment.
- **Dependency floor** — `lex-llm` raised to `>= 0.7.1` (the
  `InstanceKey#physical_id` secondary field).

### Fixed
- **Single actor registration** — the provider module no longer extends `::Legion::Extensions::Core` at file level, so the boot-time submodule walk skips it and the gem's own top-level extension load is the sole actor registration — eliminating the double-claim / `FencedPublisherError` twin.

## [0.3.2] - 2026-08-13

### Fixed
- **§1 — zero rubocop:disable** — Removed every `rubocop:disable` / `rubocop:enable` inline directive from `lib/` and `spec/`. Refactored `azure_foundry.rb`, `provider.rb`, and the fleet-worker spec to comply without suppression: extracted `ProviderClassMethods`, `ProviderDispatchMethods`, `ProviderOfferingHelpers`, `ProviderOfferingMetadata`, `ProviderCapabilityHelpers`, `Capabilities` modules and new private helpers (`extract_endpoint_from_cfg`, `extract_tier_from_cfg`, `promote_endpoint_aliases`, `promote_provider_aliases`, `resolve_usage_type`, `resolve_model_family`, `build_offering_record`, `build_offering_metadata`).
- **§9 — :default substitution removed** — Deleted `build_default_instance` and `default_instance_config` from `InstanceConfigHelpers`; `configured_instances` now reads `settings[:instances]` directly and skips entries with nil/empty endpoints. Removed `settings[:endpoint] || settings[:azure_foundry_endpoint]` `||` guard.
- **§1 — swallowed rescue** — `extract_host_port` in `InstanceIdentityHelpers` now calls `handle_exception` and re-raises on `URI::InvalidURIError` instead of silently returning `'unknown:0'`.
- **§1 — credentials .dig removed** — `apply_auth_headers` and `derive_instance_id` in the discovery actor now read only from `instance_cfg[:azure_foundry_api_key]`; the `instance_cfg.dig(:credentials, :api_key)` fallback was removed (all configs pass through `normalize_instance_config` which promotes this key).
- **§6 — circuit_state vocabulary** — Removed `circuit_state:` field from `Provider#health_baseline` and from all spec assertions; availability is probe-cleared only, not modelled as a circuit breaker.
- **spec path** — Renamed `spec/…/actors/fleet_worker_spec.rb` to `spec/…/actor/fleet_worker_spec.rb` to match the `Actor::FleetWorker` module path and satisfy `RSpec/SpecFilePathFormat`.
- **INSTANCE_DEFAULTS constant** — Extracted default instance settings hash to `AzureFoundry::INSTANCE_DEFAULTS` to reduce `default_settings` line count below the `Metrics/ModuleLength` limit.

## [0.3.1] - 2026-08-13

### Fixed
- **§1 / §8 compliance sweep** — Removed all `rubocop:disable` comments. Extracted helper modules (`HealthCheckHelpers`, `OfferingBuilderHelpers`, `InstanceConfigHelpers`, `InstanceIdentityHelpers`, `ProbeHelpers`, `ShutdownHelpers`) from `DiscoveryRefresh` to bring `Metrics/ClassLength` and `Metrics/AbcSize` into conformance.
- **§8 health firewall** — `AzureFoundryCallable#classify_server_error` now maps 503 to `:instance_unavailable` ONLY when the Azure `EndpointDeactivated` error code appears in the response body; all other 5xx (including plain 503 overload) remain `:overloaded` or `:provider_error`. `Faraday::ConnectionFailed` and `Faraday::TimeoutError` remain request-local and never promote the instance to unavailable.
- **§9 / settings guards** — Removed `def settings` override in `Provider` that called `.dig(:instances, :default)`. Removed `settings[:discovery_interval] || ...` and all `settings.dig(...)` patterns in `DiscoveryRefresh`; replaced with direct canonical path access (`settings[:discovery][:interval_seconds]`, `settings[:instances][:default][...]`).
- **§2 / single publication engine** — Removed `registry_publisher.publish_readiness_async` call from `Provider#readiness` and `registry_publisher.publish_models_async` call from `Provider#list_models`; publication is now exclusively through `Inventory::Publisher` in the discovery actor.
- Vision capability evidence in `OfferingBuilderHelpers` now emits `:unknown` / `:default_false` instead of inferring support from model name regex (which is not authoritative proof).
- Discovery interval default overridden to 3600 s via `provider_settings(discovery: { interval_seconds: 3600 })` to match the previous actor behaviour.

## [0.3.0] - 2026-08-13

### Changed
- **SSOT v3 migration** — Rewrote `DiscoveryRefresh` actor to use `Inventory::Publisher` for instance lifecycle (claim/activate/replace/remove) instead of the legacy `ScopedRefresher` mixin and `Legion::LLM::Call::Registry`.
- Added `AzureFoundryCallable` class implementing `disconnect`, `disconnected?`, `normalize_dispatch_error(error:)`, and dispatch operations (`chat`, `stream_chat`, `embed`, `count_tokens`).
- Fleet worker now passes `registry: Legion::Extensions::Llm::Inventory::Registry` for exact fleet execution.
- Instance identity derived from normalized endpoint host:port plus API key fingerprint (first 6 hex of SHA256).
- Offerings publish deployment-scoped quota domains (`azure:deployment:<name>`).
- Operation evidence covers all `Taxonomies::OPERATIONS`: chat/stream_chat supported, embed conditional on deployment type, count_tokens/image/transcribe/translate/speak/moderate unsupported.
- Bumped `lex-llm` dependency floor to `>= 0.7.0`.

### Removed
- Removed `ScopedRefresher` include and all references to `Legion::LLM::Call::Registry`.
- Removed legacy `compute_lanes_for_scope`, `scope_key`, `credential_hash` methods.

## [0.2.17] - 2026-08-07

### Fixed
- Remove dead legacy discovery calls from `#manual` actor method (closes #154).

### Removed
- Deleted `populate_auto_rules`, `refresh_discovered_models!`, and `invalidate_offerings_cache!` invocations that targeted APIs removed from the SSOT router.

## [0.2.16] - 2026-08-04

### Fixed
- Normalize canonical nested `credentials` and `provider` settings into the Azure Foundry adapter configuration while preserving flat-key aliases.

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
