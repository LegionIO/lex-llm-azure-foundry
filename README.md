# lex-llm-azure-foundry

Azure AI Foundry and Azure OpenAI provider adapter for LegionIO. Requests use the
shared `lex-llm` canonical types, OpenAI-compatible wire translator, discovery
pipeline, and inventory registry.

## Install

```ruby
gem 'lex-llm-azure-foundry'
```

Ruby 3.4+ and `lex-llm >= 0.8.11` are required. LegionIO loads the extension and
runs its discovery actor. The adapter implements chat, streamed chat, and text
embeddings; a model is eligible only when its published evidence supports the
requested operation and capabilities.

## One inventory owner

```text
model_info                  project                         declared
/models/info          Entra project deployments     bindings + resource catalog
       \                    |                        /
Azure discovery runner: parse identity and explicit evidence
                    |
lex-llm Discovery::Pipeline
    claim -> readiness -> activate/replace -> Registry snapshot
                                                |
                                  router / fleet / discover_offerings
```

`AzureFoundry::Actor::Discovery` inherits the shared discovery actor.
`AzureFoundry::Runners::Discovery` includes the shared pipeline and supplies only
Azure protocol hooks and offering evidence. The shared pipeline owns instance
reconciliation, probes, replacement, removal, weights, and health publication.
The host actor builder loads the actor files; requiring the provider alone does
not preload or conditionally define host actors.

Discovery registers `AzureFoundry::Provider` itself as the callable. There is no
Azure callable wrapper. The shared registry owns dispatch leases and retirement;
the shared provider owns execution and connection disposal.

`Provider#discover_offerings` reads activated lanes from that registry.
It does not fetch Azure or maintain another catalog. Its inherited `live:`
argument does not change that behavior.

## Deployment identity and discovery sources

Azure resource model catalogs describe base models, not deployed model names.
Microsoft's [key-authenticated endpoint ADR](https://github.com/microsoft/mosaic-apim/blob/main/docs/adr/0018-key-authenticated-backends.md)
states that API keys cannot list deployments. The authenticated resource model GET
checks access without inference, but does not prove that a deployment exists.
The project deployment API requires Entra authentication. The unsupported
`project_api_key` option introduced in 0.4.5 is removed and rejected explicitly.

Select `provider.discovery_source` explicitly for OpenAI v1 resources:

| Source | Identity source | Authentication |
| --- | --- | --- |
| `model_info` | Documented single-model `/models/info` response | Resource credential; requires `model_inference` surface |
| `project` | Foundry project `GET /deployments?api-version=v1` | Separate project bearer token or broker lease |
| `declared` | Operator deployment bindings joined to exact resource catalog model IDs | Resource credential; requires `openai_v1` surface |

The default is `model_info`, matching the default `model_inference` surface.
There is no fallback between sources. A project failure never activates declared
bindings, and a resource catalog never becomes an inventory of deployments on its own.

For API-key access, declare only deployment identity:

```yaml
instances:
  primary:
    endpoint: https://resource.example.openai.azure.com
    credentials:
      api_key: <resource-api-key>
    provider:
      surface: openai_v1
      discovery_source: declared
      deployments:
        - name: production-chat
          model: gpt-4o-mini
          model_version: '2024-07-18'
          deployment_type: GlobalStandard
        - name: embeddings
          model: text-embedding-3-small
```

Each binding requires `name` and `model`; `model_version` and `deployment_type`
are optional identity facts. Capabilities and numeric limits are not accepted.
Names must be unique within an instance. Missing or malformed bindings fail
configuration; an explicit empty array withdraws all declared offerings.
That withdrawal does not require a remote catalog read. Startup and cadence
readiness checks continue through the shared lifecycle.

Discovery authenticates `GET <resource>/openai/v1/models` and joins each binding
to an exact catalog ID. Every record's ID shape is validated, but duplicate/conflict
checks apply only to selected base-model IDs. Missing selected models, malformed
catalogs, or conflicting selected records fail the whole refresh. Only declared
names are published, unchanged, through the
shared pipeline with `publication_source: provider_static_catalog` and
`metadata.declared: true`. Multiple instances can use the same deployment name
without sharing credentials or callables. The selected binding supplies dispatch
identity; an incorrect deployment name can still produce a provider 404 at inference.

For project discovery, use a separately authorized project credential:

```yaml
instances:
  connected:
    endpoint: https://connected.example.openai.azure.com
    credentials:
      api_key: <resource-api-key>
      project_broker:
        provider: azure_identity
        qualifier: foundry_project
    provider:
      surface: openai_v1
      discovery_source: project
      project_endpoint: https://resource.example.services.ai.azure.com/api/projects/primary
      project_connection_name: connected-resource
```

`project_bearer_token` is the alternative to `project_broker`; select exactly one.
Project tokens require the `https://ai.azure.com/.default` scope and deployment-read
authorization. Resource credentials are never implicitly sent to project APIs.
Without `project_connection_name`, project discovery selects native deployments.
With it, discovery verifies the named connection target before selecting that
connection's deployments. A conclusive retarget clears stale offerings; a failed
request preserves the last complete snapshot. No connection credentials are fetched.

The project parser normalizes observed `modelVersion` and `sku.name` together,
and reads positive `capabilities.maxContextToken` / `maxOutputToken` values as
catalog limits. Observed revisions retain `provider_catalog` provenance.

`credentials.broker` and `credentials.project_broker` select existing host-owned
provider/qualifier leases. Identity issuers acquire scoped credentials; the broker
owns registered leases and renewal. Azure reads a current valid lease on each
outbound request and creates no token cache or renewal loop. These references do
not acquire OAuth consent, grant Azure permissions, or substitute the default
Graph credential. The broker names above are examples, not automatically registered
issuers. Missing or expired leases fail authentication.

For a single-model inference endpoint:

```yaml
instances:
  serverless:
    endpoint: https://resource.example.services.ai.azure.com/models
    credentials:
      api_key: <resource-api-key>
    provider:
      surface: model_inference
      discovery_source: model_info
      api_version: 2024-05-01-preview
```

Only named instances with nested `credentials` and `provider` fields are accepted.
The shared default-settings merge supplies defaults at that boundary. Source selection
does not rewrite hosts or infer project endpoints. Disabled or credential-less
instances are not claimed. Bindings refresh through normal snapshot replacement;
instance removal and endpoint/credential changes use shared callable retirement.

## Vendor model metadata

Live catalog facts take precedence, including explicit false capabilities.
When an observed project record or a declared binding identifies an exact documented
model/version/deployment-type tuple, `Provider::MODEL_METADATA` supplies absent vendor facts with
`source: model_metadata`. This immutable table is not operator tuning, a second
inventory, or a model-name heuristic. Unknown versions or deployment types remain
unknown. Both parser boundaries construct one explicit lookup tuple; declared
identity fields remain declarations in metadata and never become observed revision evidence.

| Exact model | Version | Deployment type | Context | Max output | Thinking |
| --- | --- | --- | --- | --- | --- |
| `gpt-4o-mini` | `2024-07-18` | `GlobalStandard` | 128,000 | 16,384 | Unsupported |
| `gpt-4.1` | `2025-04-14` | `GlobalStandard` | 1,047,576 | 32,768 | Unsupported |
| `gpt-5-mini` | `2025-08-07` | `GlobalStandard` | 400,000 | 128,000 | Supported |

The same exact tuples document chat, streaming, tools, and vision support.
The GPT-4.1 GlobalStandard facts do not apply to regional Standard, provisioned,
batch, or unknown SKUs. Sources: [Microsoft model capability tables](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure?pivots=azure-openai),
[deployment types](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/deployment-types),
and [Azure GPT-4.1 launch](https://azure.microsoft.com/en-us/blog/announcing-the-gpt-4-1-model-series-for-azure-ai-foundry-developers/).

The two GPT-4 tuples publish unsupported thinking evidence with `model_metadata`
provenance. [OpenAI identifies GPT-4.1 as non-reasoning](https://developers.openai.com/api/docs/models/gpt-4.1),
and [Microsoft's Azure migration guidance identifies GPT-4o-mini as not supporting the reasoning parameter](https://github.com/Azure-Samples/azure-openai-to-responses/blob/main/skills/azure-openai-to-responses/references/troubleshooting.md#L59).
Explicit live catalog values retain precedence, including positive reasoning or
thinking evidence. Other model names, versions, and SKUs do not inherit this negative fact.

## Native request controls

The shared payload builder keeps `Canonical::Params.max_tokens` unchanged and uses
the provider's protocol hook to choose its wire name: `max_completion_tokens` for
OpenAI v1, or `max_tokens` for model inference. It sends only that key, and omits
an absent limit. This applies equally to buffered and streaming requests.

Native reasoning effort values remain model- and API-specific. For GPT-5 mini,
the canonical `low`, `medium`, and `high` levels are supported; `max` is unsupported
on Chat Completions. Azure also documents a native `minimal` level, which the
canonical effort enum does not currently represent.
The canonical budget conversion maps 16,384 tokens to `high`, while budgets above
24,576 resolve to `max`. This adapter does not silently lower an unsupported effort.
Callers must supply controls supported by their selected deployment and API.
See [Azure reasoning API constraints](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning#api-and-feature-support).

## Evidence and failure behavior

- Explicit catalog capability flags, including false values, become canonical
  evidence. Names such as “embed” or “vision” do not establish capabilities.
- Facts absent from both the live catalog and exact vendor metadata remain unknown.
  Operator permissions and configured limits are not relabeled as provider facts.
- Deployment names do not establish quota sharing across resources. Without
  authoritative quota-domain evidence, offerings leave that mapping empty.
- Provider execution inherits `chat`, `stream_chat`, `complete`, `embed`, `health`,
  and `discover_offerings` from `lex-llm`. The shared fleet worker reconstructs
  serialized canonical controls before dispatch. Azure has no second execution
  funnel, parameter-reconstruction path, or capability-name guesses.
- Error normalization starts with the shared classifier. Azure refines only
  structured error codes paired with their HTTP status; free-text phrases and
  generic 404s cannot establish endpoint health or deployment existence.
- Context and output limits use valid positive integer catalog fields first,
  then the exact documented vendor tuple where available.
- Deployment names remain distinct even when several deployments share one base
  model. Duplicate records with identical facts are collapsed; conflicting facts
  fail the refresh.
- All deployment pages must succeed before replacement. Pagination is bounded,
  cycles are rejected, and continuation URLs must stay on the same project
  deployment endpoint.
- Failed or malformed refreshes retain the last good snapshot. A valid empty
  deployment list can publish an empty snapshot.
- Readiness performs a non-generation data-plane GET. It proves connectivity and
  authentication, not that every base model is deployed.
- The selected inventory model string reaches provider dispatch unchanged.
  Fleet execution uses the shared `Fleet::ProviderResponder`.

The inherited token counter returns an estimate; Azure has no portable native
token-count endpoint, so authoritative native counting is not advertised.

## Defaults

All Azure connection and discovery defaults are defined in
`lib/legion/extensions/llm/azure_foundry/settings.rb` and returned through the
standard provider `default_settings` contract.

| Setting under `extensions.llm.azure_foundry` | Default |
| --- | --- |
| `discovery.interval_seconds` | 3600 |
| `discovery.request_timeout` / `open_timeout` | 10 / 5 seconds |
| `discovery.health_timeout` / `health_open_timeout` | 5 / 3 seconds |
| `discovery.max_pages` | 100 |
| `instances.default.tier` | `cloud` |
| `instances.default.provider.surface` | `model_inference` |
| `instances.default.provider.discovery_source` | `model_info` |
| `instances.default.provider.deployments` | `nil` |
| `instances.default.provider.api_version` | `2024-05-01-preview` |
| `instances.default.provider.project_api_version` | `v1` |

## Verification

Run the full suite and linter:

```sh
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

Specs exercise the shared SSOT conformance kit, real inventory publication,
canonical callable payloads, documented model-info parsing, project pagination,
authentication boundaries, failed-refresh retention, and explicit evidence.
Broker tests load the real host broker, lease, and renewer from the test dependency.
Actor tests load the actual host actors and helpers. Publication tests register
actual provider instances; only external HTTP transport and token issuance are
controlled fixtures.

Microsoft references:
[model-inference info](https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-model-info/get-model-info?view=rest-microsoftfoundry-model-inference-2024-05-01-preview),
[project deployments](https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/aiproject#deployments---list),
[Azure endpoint and deployment naming](https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/endpoints?view=foundry-classic).
