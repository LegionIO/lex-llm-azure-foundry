# lex-llm-azure-foundry

Azure AI Foundry and Azure OpenAI provider adapter for LegionIO. Requests use the
shared `lex-llm` canonical types, OpenAI-compatible wire translator, discovery
pipeline, and inventory registry.

## Install

```ruby
gem 'lex-llm-azure-foundry'
```

Ruby 3.4+ and `lex-llm >= 0.8.0` are required. LegionIO loads the extension and
runs its discovery actor. The adapter implements chat, streamed chat, and text
embeddings; a model is eligible only when its published evidence supports the
requested operation and capabilities.

## One inventory owner

```text
Azure deployment API or model-inference /info
                    |
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

`Provider#discover_offerings` reads activated lanes from that registry.
It does not fetch Azure or maintain another catalog. Its inherited `live:`
argument does not change that behavior.

## Model catalog versus deployment inventory

Azure resource `/openai/v1/models` responses describe models, which do not by
themselves prove that matching deployments exist. Inference requests need the
**deployment name**. Publishing a base model ID as a deployment can produce
`DeploymentNotFound` even when catalog authentication succeeds.

For OpenAI v1 resources, configure the Foundry project endpoint and its
project-scoped credential or broker reference. Discovery reads
`GET <project_endpoint>/deployments?api-version=v1` and publishes the selected
deployment's `name`. The publisher-specific model name is metadata, not dispatch identity.
OpenAI v1 discovery requires this project source. There is no resource model-list
fallback or inference of deployments from base-model names.

Each configured instance binds to one resource endpoint and credential source,
just as other providers do. With no `project_connection_name`, it publishes the
project-native deployments. Set `provider.project_connection_name` to bind an
instance to a connected Azure OpenAI resource. Discovery verifies the named
connection's metadata and target endpoint before publishing only that connection's
deployments. The model string remains the deployment name; two instances may serve
the same deployment name without sharing a callable or credentials.

A successful connection response that points elsewhere clears the old scope's
offerings. A transport/authentication/malformed-response failure retains the last
complete snapshot under the shared lifecycle. No credentials are fetched from
project connection metadata or forwarded between resource instances.

Project discovery uses its own bearer credential with the
`https://ai.azure.com/.default` scope. The resource API key and resource bearer
token are never forwarded to the project endpoint.

`credentials.broker` and `credentials.project_broker` accept explicit
`provider` / `qualifier` references to the existing `Legion::Identity::Broker`.
The broker owns credential acquisition and renewal. Azure reads its current valid
lease for every inference request, readiness check, project page, and connection
lookup. It keeps no token cache or renewal worker. Missing/expired leases fail
authentication; the adapter never substitutes a default Graph credential.

Broker reference names from JSON are converted to symbols, matching the host's
symbol-qualified registrations. The identity issuer registered under each reference
must provide the appropriate audience: `https://ai.azure.com/.default` for project
operations and the resource's inference audience for resource requests. These
references select existing scoped leases; they do not request OAuth consent or
mint new scopes. Broker mode requires the LegionIO identity runtime. Static
API-key/bearer operation remains available without loading that host service.
The resource configures exactly one credential source: API key, bearer token, or
broker reference. Project discovery uses either a project bearer token or a
project broker reference; it does not accept resource API keys.
Ambiguous combinations are rejected; a failed source is never
replaced by another credential source.

Example settings under `extensions.llm.azure_foundry`:

```yaml
instances:
  primary:
    endpoint: https://resource.example.openai.azure.com
    tier: cloud
    credentials:
      api_key: <resource-api-key>
      project_bearer_token: <project-scoped-bearer-token>
    provider:
      surface: openai_v1
      project_endpoint: https://resource.example.services.ai.azure.com/api/projects/primary
      project_api_version: v1
  connected:
    endpoint: https://connected.example.openai.azure.com
    credentials:
      broker:
        provider: azure_identity
        qualifier: cognitive_services
      project_broker:
        provider: azure_identity
        qualifier: foundry_project
    provider:
      surface: openai_v1
      project_endpoint: https://resource.example.services.ai.azure.com/api/projects/primary
      project_connection_name: connected-resource
```

The broker names above are examples: use provider/qualifier pairs already
registered by your identity integration. Resource and project references are
independent and are never implicitly exchanged.

The data-plane endpoint may already end in `/openai/v1`. The project endpoint
is independently configured; the adapter does not guess a project or transform
an account hostname into one.

For an existing model-inference endpoint:

```yaml
instances:
  serverless:
    endpoint: https://resource.example.services.ai.azure.com/models
    credentials:
      api_key: <resource-api-key>
    provider:
      surface: model_inference
      api_version: 2024-05-01-preview
```

The documented `/models/info` response identifies the deployed model through
`model_name` and its operation through `model_type`. Discovery and inference
share the same URL builder, so a configured `/models` suffix is not duplicated.

Only named instances with nested `credentials` and `provider` fields are accepted.
Top-level instance shortcuts, flat credential/provider fields, and endpoint aliases
are removed. The shared default-settings merge supplies defaults once at this
configuration boundary. Dispatch receives the resulting explicit configuration.
Disabled or credential-less instances are not claimed.
An explicit broker binding remains claimable while its lease is temporarily
unavailable, allowing the existing readiness/probe lifecycle to recover. Binding
changes reclaim the callable through the shared physical-identity lifecycle;
ordinary broker token renewal does not replace the callable.

## Evidence and failure behavior

- Explicit catalog capability flags, including false values, become canonical
  evidence. Names such as “embed” or “vision” do not establish capabilities.
- Missing operation, tool, vision, thinking, or limit facts remain unknown.
  Operator permissions and configured limits are not relabeled as provider facts.
- Deployment names do not establish quota sharing across resources. Without
  authoritative quota-domain evidence, offerings leave that mapping empty.
- Provider execution inherits `chat`, `stream_chat`, `complete`, `embed`, `health`,
  and `discover_offerings` from `lex-llm`. The callable packages canonical fields
  for those methods; Azure has no second execution funnel or capability-name guesses.
- Context and output limits come from valid positive integer catalog fields.
  No model-size lookup table supplies missing limits.
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
Only external HTTP transport and the token issuer are controlled fixtures.

Microsoft references:
[model-inference info](https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-model-info/get-model-info?view=rest-microsoftfoundry-model-inference-2024-05-01-preview),
[project deployments](https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/aiproject#deployments---list),
[Azure endpoint and deployment naming](https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/endpoints?view=foundry-classic).
