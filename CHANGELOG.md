# Changelog

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
