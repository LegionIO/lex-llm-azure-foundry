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
- Azure AI Foundry model info health checks through `GET /models/info?api-version=...` when `live: true`
- Azure OpenAI v1-compatible endpoint support through `/openai/v1/chat/completions` and `/openai/v1/embeddings`
- Offline-first offering discovery from configured deployments
- Deployment-name-preserving routing metadata for hosted Azure deployments
- Explicit `model_family` and `canonical_model_alias` metadata for deployments whose base model cannot be proven from Azure metadata
- Shared OpenAI-compatible request and response mapping through `Legion::Extensions::Llm::Provider::OpenAICompatible`
- Shared registry availability publishing through `Legion::Extensions::Llm::RegistryPublisher` when transport is available
- Provider-owned fleet request handling through `Legion::Extensions::Llm::Fleet::ProviderResponder`

## Architecture

```text
Legion::Extensions::Llm::AzureFoundry
|-- Provider              # Azure AI Foundry and Azure OpenAI hosted provider surface
|   `-- Capabilities      # Capability predicates inferred from deployment metadata and model naming
|-- Actor::FleetWorker    # Subscription actor for provider-owned fleet requests
|-- Runners::FleetWorker  # Runner entrypoint that delegates to lex-llm ProviderResponder
`-- VERSION
```

`AzureFoundry.discover_instances` reads `extensions.llm.azure_foundry` settings and returns provider instance configs. The base Legion LLM runtime can use those configs to populate the provider registry and routing inventory; this gem does not write `legion-llm` registry state itself at require time.

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/azure_foundry.rb` | Entry point, provider defaults, instance discovery, shared registry publisher |
| `lib/legion/extensions/llm/azure_foundry/provider.rb` | Provider implementation with chat, stream, embed, health, readiness, model listing, and offering discovery |
| `lib/legion/extensions/llm/azure_foundry/actors/fleet_worker.rb` | Subscription actor gated by ProviderResponder fleet settings |
| `lib/legion/extensions/llm/azure_foundry/runners/fleet_worker.rb` | Fleet request runner that delegates execution to `ProviderResponder.call` |
| `lib/legion/extensions/llm/azure_foundry/version.rb` | `VERSION` constant |

## Configuration

Configured instances can be supplied through Legion settings under `extensions.llm.azure_foundry`. A top-level endpoint creates a `:settings` instance; entries under `instances` create named instances.

```yaml
extensions:
  llm:
    azure_foundry:
      endpoint: https://example.services.ai.azure.com
      api_key: env://AZURE_INFERENCE_CREDENTIAL
      bearer_token: env://AZURE_FOUNDRY_BEARER_TOKEN
      api_version: 2024-05-01-preview
      surface: model_inference
      deployments:
        - deployment: gpt-4o-prod
          model_family: openai
          canonical_model_alias: gpt-4o
          usage_type: inference
        - deployment: embedding-prod
          model_family: openai
          canonical_model_alias: text-embedding-3-small
          usage_type: embedding
      instances:
        prod:
          endpoint: https://prod.services.ai.azure.com
          api_key: env://AZURE_INFERENCE_CREDENTIAL
          api_version: 2024-05-01-preview
          surface: model_inference
          deployments:
            - deployment: gpt-4o-prod
              model_family: openai
              canonical_model_alias: gpt-4o
              usage_type: inference
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
  config.azure_foundry_deployments = [
    {
      deployment: 'gpt-4o-prod',
      model_family: :openai,
      canonical_model_alias: 'gpt-4o',
      usage_type: :inference
    }
  ]
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
#         surface: nil,
#         deployments: []
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

provider.discover_offerings(live: false)
provider.offering_for(model: 'gpt-4o-prod', model_family: :openai, canonical_model_alias: 'gpt-4o')
provider.health(live: false)
provider.readiness(live: false)
provider.list_models
provider.chat(messages: messages, model: 'gpt-4o-prod')
provider.stream(messages: messages, model: 'gpt-4o-prod') { |chunk| puts chunk.content }
provider.embed(text: ['hello'], model: 'embedding-prod')
provider.count_tokens(messages: messages, model: 'gpt-4o-prod')
```

`discover_offerings(live: false)` does not call Azure. It maps configured deployments into `Legion::Extensions::Llm::Routing::ModelOffering` values with `provider_family: :azure_foundry`.

`health(live: true)` calls the documented model-info endpoint for the configured model-inference surface. Keep `live: false` for startup paths and tests that must not require Azure.

`count_tokens` returns a structured unsupported result by default because the Microsoft REST contract used here does not define a portable token-counting endpoint across Azure AI Foundry deployments.

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The actor is enabled only when at least one discovered instance has `fleet.respond_to_requests: true`.

Fleet execution is delegated to `Legion::Extensions::Llm::Fleet::ProviderResponder` from `lex-llm`; this provider supplies the provider family, provider class, discovered instances, and delivery metadata.

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

## Failure Behavior

Live discovery and health-check failures are reported with `handle_exception(e, level: :warn, handled: true, operation: ...)` before returning degraded metadata. Offline discovery, provider configuration, and fleet actor enablement should not require live Azure connectivity.
