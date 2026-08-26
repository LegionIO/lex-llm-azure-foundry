# lex-llm-azure-foundry

LegionIO LLM provider extension for Azure AI Foundry Models and Azure OpenAI hosted deployments.

This gem lives under `Legion::Extensions::Llm::AzureFoundry`. It depends on `lex-llm >= 0.4.3` for provider contracts, routing metadata, registry publishing helpers, and provider-owned fleet request handling. It does not require or depend on `legion-llm` at runtime; Legion LLM orchestration can load this provider gem and consume its discovery metadata.

Load it with:

```ruby
require 'legion/extensions/llm/azure_foundry'
```

## What It Provides

- Provider family `:azure_foundry`
- Azure AI Foundry model inference chat completions through `POST /models/chat/completions?api-version=...`
- Azure AI Foundry model inference embeddings through `POST /models/embeddings?api-version=...`
- Live model catalog discovery through the surface's discovery endpoint
  (`GET /models/info?api-version=...` on the model-inference surface, `GET /models` on the
  OpenAI-compatible surface) — the same endpoint doubles as the readiness probe
- Azure OpenAI v1-compatible endpoint support through `/openai/v1/chat/completions` and `/openai/v1/embeddings`
- Standard lex-llm offering discovery: `list_models` fetches the live catalog and
  `discover_offerings` derives offerings through the shared base-class flow,
  exactly like every other provider
- Shared `ModelCatalogParser` — the single module both the Provider's `list_models`
  and the SSOT v3 `DiscoveryRefresh` actor parse the wire catalog through
- Shared OpenAI-compatible request and response mapping through `Legion::Extensions::Llm::Provider::OpenAICompatible`
- Shared registry availability publishing through `Legion::Extensions::Llm::RegistryPublisher` when transport is available
- Provider-owned fleet request handling through `Legion::Extensions::Llm::Fleet::ProviderResponder`

## Architecture

```text
Legion::Extensions::Llm::AzureFoundry
|-- Provider              # Azure AI Foundry and Azure OpenAI hosted provider surface
|   |-- Capabilities      # Capability predicates inferred from catalog metadata and model naming
|   `-- catalog discovery # live list_models through ModelCatalogParser
|-- ModelCatalogParser    # shared live-catalog envelope/entry parsing
|-- Actor::DiscoveryRefresh # SSOT v3 periodic discovery (catalog fetch, OfferingDrafts, probes)
|-- Actor::FleetWorker    # Subscription actor for provider-owned fleet requests
|-- Runners::FleetWorker  # Runner entrypoint that delegates to lex-llm ProviderResponder
`-- VERSION
```

`AzureFoundry.discover_instances` reads `extensions.llm.azure_foundry` settings and returns provider instance configs. The base Legion LLM runtime can use those configs to populate the provider registry and routing inventory; this gem does not write `legion-llm` registry state itself at require time.

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/azure_foundry.rb` | Entry point, provider defaults, instance discovery, shared registry publisher |
| `lib/legion/extensions/llm/azure_foundry/provider.rb` | Provider implementation with chat, stream, embed, health, readiness, and live model listing |
| `lib/legion/extensions/llm/azure_foundry/model_catalog_parser.rb` | Shared live-catalog envelope and entry parsing |
| `lib/legion/extensions/llm/azure_foundry/actors/discovery_refresh.rb` | SSOT v3 periodic discovery actor (catalog fetch, OfferingDrafts, readiness probes) |
| `lib/legion/extensions/llm/azure_foundry/actors/fleet_worker.rb` | Subscription actor gated by ProviderResponder fleet settings |
| `lib/legion/extensions/llm/azure_foundry/runners/fleet_worker.rb` | Fleet request runner that delegates execution to `ProviderResponder.call` |
| `lib/legion/extensions/llm/azure_foundry/version.rb` | `VERSION` constant |

## Configuration

Configured instances can be supplied through Legion settings under `extensions.llm.azure_foundry`. A top-level endpoint creates a `:settings` instance; entries under `instances` create named instances.

Models are **discovered from the endpoint**, not configured: nothing about the model set lives in settings. The discovery actor (and `list_models`) fetches the model catalog from the instance's discovery endpoint and publishes whatever it reports.

```yaml
extensions:
  llm:
    azure_foundry:
      endpoint: https://example.services.ai.azure.com
      api_key: env://AZURE_INFERENCE_CREDENTIAL
      bearer_token: env://AZURE_FOUNDRY_BEARER_TOKEN
      api_version: 2024-05-01-preview
      surface: model_inference
      instances:
        prod:
          endpoint: https://prod.services.ai.azure.com
          api_key: env://AZURE_INFERENCE_CREDENTIAL
          api_version: 2024-05-01-preview
          surface: model_inference
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

The provider also supports direct configuration through `Legion::Extensions::Llm.configure` for tests and embedded use:

```ruby
Legion::Extensions::Llm.configure do |config|
  config.azure_foundry_endpoint = ENV.fetch('AZURE_FOUNDRY_ENDPOINT')
  config.azure_foundry_api_key = ENV['AZURE_INFERENCE_CREDENTIAL']
  config.azure_foundry_bearer_token = ENV['AZURE_FOUNDRY_BEARER_TOKEN']
  config.azure_foundry_api_version = '2024-05-01-preview'
  config.azure_foundry_surface = :model_inference
end
```

Use `:openai_v1` when the endpoint should be treated as the OpenAI v1-compatible Azure route. The provider appends `/openai/v1` when the configured endpoint does not already include it.

## Default Settings

```ruby
Legion::Extensions::Llm::AzureFoundry.default_settings
# {
#   enabled: true,
#   provider_family: :azure_foundry,
#   instances: {
#     default: {
#       endpoint: nil,
#       tier: :frontier,
#       transport: :http,
#       credentials: {
#         api_key: nil,
#         bearer_token: nil
#       },
#       provider: {
#         api_version: "2024-05-01-preview",
#         surface: nil
#       },
#       usage: { inference: true, embedding: true, image: false },
#       limits: { concurrency: 4 },
#       fleet: {
#         enabled: false,
#         respond_to_requests: false,
#         capabilities: [:chat, :stream_chat, :embed],
#         lanes: [],
#         concurrency: 4,
#         queue_suffix: nil
#       }
#     }
#   }
# }
```

## Provider Methods

```ruby
provider = Legion::Extensions::Llm::AzureFoundry.provider_class.new(Legion::Extensions::Llm.config)

provider.list_models
provider.discover_offerings(live: true)
provider.health(live: false)
provider.readiness(live: false)
provider.chat(messages: messages, model: 'gpt-4o-prod')
provider.stream(messages: messages, model: 'gpt-4o-prod') { |chunk| puts chunk.content }
provider.embed(text: ['hello'], model: 'embedding-prod')
provider.count_tokens(messages: messages, model: 'gpt-4o-prod')
```

`list_models` and `discover_offerings(live: true)` fetch the model catalog from the instance's discovery endpoint. `discover_offerings(live: false)` returns the last cached discovery result without calling Azure — the periodic `DiscoveryRefresh` actor keeps that cache warm, exactly like the other providers.

`health(live: true)` calls the surface's discovery endpoint (the non-billable readiness probe). Keep `live: false` for startup paths and tests that must not require Azure.

`count_tokens` returns a structured unsupported result by default because the Microsoft REST contract used here does not define a portable token-counting endpoint across Azure AI Foundry deployments.

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The actor is enabled only when at least one discovered instance has `fleet.respond_to_requests: true`.

Fleet execution is delegated to `Legion::Extensions::Llm::Fleet::ProviderResponder` from `lex-llm`; this provider supplies the provider family, provider class, discovered instances, and delivery metadata.

## Routing Metadata

The catalog entry's model identity (`id` / `name` / `model_name` / `deployment_name` / `model`) becomes the offering `model` and `provider_native_key` — the same routable id the endpoint accepts. When the catalog reports a base model name distinct from the routable id, it rides along as `canonical_model_alias`; `model_family` is inferred from the model name as a routing hint (never as capability evidence).

Supported `model_family` values are intentionally open-ended symbols, including:

- `:openai`
- `:mistral`
- `:meta`
- `:xai`
- `:anthropic`
- `:microsoft`

## Failure Behavior

Live discovery and health-check failures are reported with `handle_exception(e, level: :warn, handled: true, operation: ...)` before returning degraded metadata. A failed catalog fetch in the discovery actor keeps the last complete snapshot (it never replaces it with an empty set); provider configuration and fleet actor enablement do not require live Azure connectivity.
