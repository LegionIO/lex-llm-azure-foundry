# lex-llm-azure-foundry

LegionIO LLM provider extension for Azure AI Foundry Models and Azure OpenAI hosted deployments.

This gem lives under `Legion::Extensions::Llm::AzureFoundry` and depends on `lex-llm >= 0.4.0` for shared provider-neutral routing, response normalization, fleet envelopes, model-offering, readiness, canonical-alias, and schema primitives.

Load it with `require 'legion/extensions/llm/azure_foundry'`.

## What It Provides

- `Legion::Extensions::Llm::Provider` registration as `:azure_foundry`
- Azure AI Foundry model inference chat completions through `POST /models/chat/completions?api-version=...`
- Azure AI Foundry model inference embeddings through `POST /models/embeddings?api-version=...`
- Azure AI Foundry model info health check through `GET /models/info?api-version=...` when `live: true`
- Azure OpenAI v1-compatible endpoint support through `/openai/v1/chat/completions` and `/openai/v1/embeddings`
- Deployment-name-preserving routing offerings for hosted Azure deployments
- Explicit `model_family` and `canonical_model_alias` metadata for deployments whose base model cannot be proven from Azure metadata
- Offline-first discovery from configured deployments
- Shared OpenAI-compatible request and response mapping via `Legion::Extensions::Llm::Provider::OpenAICompatible`
- Conservative token-counting metadata when no portable Azure token-counting REST endpoint is configured
- Best-effort `llm.registry` event publishing for readiness and model availability via AMQP when transport is available

## Architecture

```
Legion::Extensions::Llm::AzureFoundry
├── Provider              # Azure AI Foundry and Azure OpenAI hosted provider surface
│   └── Capabilities      # Capability predicates inferred from deployment metadata and model naming
├── RegistryPublisher     # Best-effort async publisher for llm.registry availability events
├── RegistryEventBuilder  # Builds sanitized lex-llm registry envelopes for provider state
├── Transport/
│   ├── Messages::RegistryEvent  # AMQP message for llm.registry events
│   └── Exchanges::LlmRegistry  # Topic exchange for provider availability events
└── VERSION
```

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/azure_foundry.rb` | Entry point, provider registration, default settings |
| `lib/legion/extensions/llm/azure_foundry/provider.rb` | Provider implementation with chat, stream, embed, health, readiness, discovery |
| `lib/legion/extensions/llm/azure_foundry/registry_publisher.rb` | Async registry event publishing with transport guards |
| `lib/legion/extensions/llm/azure_foundry/registry_event_builder.rb` | Sanitized registry envelope construction |
| `lib/legion/extensions/llm/azure_foundry/transport/messages/registry_event.rb` | AMQP message class for registry events |
| `lib/legion/extensions/llm/azure_foundry/transport/exchanges/llm_registry.rb` | Topic exchange definition for llm.registry |
| `lib/legion/extensions/llm/azure_foundry/version.rb` | `VERSION` constant |

## Observability

Every class and module uses `Legion::Logging::Helper`:

- **AzureFoundry** module: `extend Legion::Logging::Helper`
- **Provider**: inherits `include Legion::Logging::Helper` from `Legion::Extensions::Llm::Provider`
- **RegistryPublisher**: `include Legion::Logging::Helper`
- **RegistryEventBuilder**: `include Legion::Logging::Helper`

All rescue blocks call `handle_exception(e, level:, handled:, operation:)` for structured exception reporting. Key actions emit info-level log lines including discover_offerings, health checks, readiness, model listing, chat, stream, embed, and registry publish operations.

## API Contract

The implementation follows Microsoft Learn REST documentation for Azure AI Foundry Models:

- Azure AI Foundry model inference endpoints use deployment names as the request `model`.
- The model inference endpoint supports chat completions and embeddings.
- The documented model-info endpoint is used only for explicit live health checks.
- Azure deployment metadata is not assumed to reliably prove base model family or version, so routing metadata should be configured explicitly.

## Defaults

```ruby
Legion::Extensions::Llm::AzureFoundry.default_settings
# {
#   provider_family: :azure_foundry,
#   discovery: { enabled: true, live: false },
#   instances: {
#     default: {
#       endpoint: "https://<resource>.services.ai.azure.com",
#       api_version: "2024-05-01-preview",
#       surface: :model_inference,
#       tier: :frontier,
#       transport: :http,
#       credentials: {
#         api_key: "env://AZURE_INFERENCE_CREDENTIAL",
#         bearer_token: "env://AZURE_FOUNDRY_BEARER_TOKEN",
#         entra_scope: "https://cognitiveservices.azure.com/.default"
#       },
#       deployments: [],
#       usage: { inference: true, embedding: true, token_counting: false },
#       limits: { concurrency: 4 }
#     }
#   }
# }
```

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`.

```yaml
extensions:
  llm:
    azure_foundry:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.azure_foundry_endpoint = ENV.fetch("AZURE_FOUNDRY_ENDPOINT")
  config.azure_foundry_api_key = ENV["AZURE_INFERENCE_CREDENTIAL"]
  config.azure_foundry_bearer_token = ENV["AZURE_FOUNDRY_BEARER_TOKEN"]
  config.azure_foundry_api_version = "2024-05-01-preview"
  config.azure_foundry_surface = :model_inference
  config.azure_foundry_deployments = [
    {
      deployment: "gpt-4o-prod",
      model_family: :openai,
      canonical_model_alias: "gpt-4o",
      usage_type: :inference
    },
    {
      deployment: "mistral-large-prod",
      model_family: :mistral,
      canonical_model_alias: "mistral-large",
      usage_type: :inference
    },
    {
      deployment: "embedding-prod",
      model_family: :openai,
      canonical_model_alias: "text-embedding-3-small",
      usage_type: :embedding
    }
  ]
end
```

Use `config.azure_foundry_surface = :openai_v1` when the target endpoint should be treated as the OpenAI v1-compatible Azure route. The provider appends `/openai/v1` when the configured endpoint does not already include it.

## Provider Methods

```ruby
provider = Legion::Extensions::Llm::AzureFoundry.provider_class.new(Legion::Extensions::Llm.config)

provider.discover_offerings(live: false)
provider.offering_for(model: "gpt-4o-prod", model_family: :openai, canonical_model_alias: "gpt-4o")
provider.health(live: false)
provider.readiness(live: false)
provider.list_models
provider.chat(messages, model: "gpt-4o-prod")
provider.stream(messages, model: "gpt-4o-prod") { |chunk| puts chunk.content }
provider.embed(["hello"], model: "embedding-prod")
provider.count_tokens(messages, model: "gpt-4o-prod")
```

`discover_offerings(live: false)` never calls Azure. It maps configured deployments into `Legion::Extensions::Llm::Routing::ModelOffering` values with `provider_family: :azure_foundry`.

`health(live: true)` calls the documented model-info endpoint for the configured model-inference surface. Keep `live: false` for startup paths and tests that must not require Azure.

`count_tokens` returns a structured unsupported result by default because the Microsoft REST contract used here does not define a portable token-counting endpoint across Azure AI Foundry deployments.

## Routing Metadata

Azure deployments are aliases. A deployment name can hide provider, model, and version details, so this extension preserves the deployment name as `model` and treats `canonical_model_alias` and `model_family` as routing metadata.

Supported `model_family` values are intentionally open-ended symbols, including:

- `:openai`
- `:mistral`
- `:meta`
- `:xai`
- `:anthropic`
- `:microsoft`

When `model_family` or `canonical_model_alias` is missing, offerings include `requires_explicit_model_metadata: true`.
