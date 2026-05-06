# Changelog

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
