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
project-scoped bearer credential. Discovery reads
`GET <project_endpoint>/deployments?api-version=v1` and publishes each deployment's
`name`. The publisher-specific model name is metadata, not dispatch identity.
A gateway catalog that explicitly supplies `deployment_name` can also be read;
bare base-model entries are rejected.

Project discovery uses its own bearer credential with the
`https://ai.azure.com/.default` scope. The resource API key and resource bearer
token are never forwarded to the project endpoint. Credential retrieval and
refresh remain owned by Legion settings and the configured credential source.

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
```

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

A top-level endpoint still creates the `settings` instance. Nested credentials
and provider settings are canonical; existing flat credential/provider aliases
remain accepted. Disabled or credential-less instances are not claimed.

## Evidence and failure behavior

- Explicit catalog capability flags, including false values, become canonical
  evidence. Names such as “embed” or “vision” do not establish capabilities.
- Missing operation, tool, vision, thinking, or limit facts remain unknown.
  Operator permissions and configured limits are not relabeled as provider facts.
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

Microsoft references:
[model-inference info](https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-model-info/get-model-info?view=rest-microsoftfoundry-model-inference-2024-05-01-preview),
[project deployments](https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/aiproject#deployments---list),
[Azure endpoint and deployment naming](https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/endpoints?view=foundry-classic).
