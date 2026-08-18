# frozen_string_literal: true

require 'spec_helper'
require 'faraday'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# Spec double standing in for AzureFoundry::Provider at the dispatch boundary.
# The production AzureFoundryCallable is used verbatim; only the per-instance
# Provider (the HTTP boundary) is replaced so specs never touch the network.
class RecordingAzureFoundryProvider
  attr_reader :call_count

  def initialize
    @call_count = 0
  end

  def chat(**kwargs)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: kwargs[:model] }
  end

  def stream(**kwargs)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: kwargs[:model] }
  end

  def embed(**kwargs)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: kwargs[:model] }
  end

  def count_tokens(**)
    @call_count += 1
    { token_count: 42 }
  end
end

# Captures the exact `model:` value each dispatch op hands to the provider
# boundary, proving the D15 raw-string-model handling (the counting double
# above cannot, because it ignores model).
class ModelCapturingAzureFoundryProvider
  attr_reader :received_models

  def initialize
    @received_models = {}
  end

  def chat(model:, **)
    record(:chat, model)
  end

  def stream(model:, **)
    record(:stream_chat, model)
  end

  def embed(model:, **)
    record(:embed, model)
  end

  def count_tokens(model:, **)
    record(:count_tokens, model)
  end

  private

  def record(operation, model)
    @received_models[operation] = model
    {}
  end
end

# Harness class for Azure Foundry SSOT v3 conformance testing. Implements the
# full interface required by the shared conformance examples without touching
# any external service: the production AzureFoundryCallable is used, with the
# per-instance Provider (HTTP boundary) replaced by a recording double.
# Identity and offering-draft construction delegate to the production actor's
# real helpers (no harness re-implementation that can drift).
class AzureFoundrySsotHarness
  # `name` is the operator's CONFIG NAME — the instance_id the discovery actor
  # publishes (the key the router resolves instances.<name> settings by).
  INSTANCE_CONFIGS = [
    {
      name: 'eastus-prod',
      azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
      tier: :cloud,
      azure_foundry_api_key: 'ak-azure-eastus-prod-001',
      azure_foundry_surface: :model_inference,
      azure_foundry_api_version: '2024-05-01-preview',
      azure_foundry_deployments: [
        { deployment: 'gpt-4o-deployment', model: 'gpt-4o', model_family: :openai,
          canonical_model_alias: 'gpt-4o', usage_type: :inference, context_window: 128_000 }
      ]
    }.freeze,
    {
      name: 'westus-prod',
      azure_foundry_endpoint: 'https://westus-prod.openai.azure.com',
      tier: :cloud,
      azure_foundry_api_key: 'ak-azure-westus-prod-002',
      azure_foundry_surface: :openai_v1,
      azure_foundry_api_version: '2024-05-01-preview',
      azure_foundry_deployments: [
        { deployment: 'gpt-4o-mini-deployment', model: 'gpt-4o-mini', model_family: :openai,
          canonical_model_alias: 'gpt-4o-mini', usage_type: :inference, context_window: 128_000 }
      ]
    }.freeze
  ].freeze

  def provider_family = :azure_foundry
  def instance_configs = INSTANCE_CONFIGS

  # Identity is the operator's config NAME (the router keys settings lookups
  # by it). The derived endpoint id is the secondary physical field.
  def instance_id(instance_config:)
    instance_config[:name].to_s
  end

  def physical_id(instance_config:)
    discovery_actor.send(:derive_physical_id, instance_cfg: instance_config)
  end

  def build_callable(instance_config:)
    Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable.new(
      instance_cfg: instance_config,
      logger: Logger.new(File::NULL),
      provider: RecordingAzureFoundryProvider.new
    )
  end

  def build_offering_drafts(instance_config: instance_configs.first, tier: :cloud, **)
    config = instance_config.merge(tier: tier)
    instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: provider_family,
      instance_id: instance_id(instance_config: config),
      physical_id: physical_id(instance_config: config)
    )
    discovery_actor.send(:discover_offerings_for_instance, instance_cfg: config, instance_key: instance_key)
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Azure Foundry health returned 200',
      metadata: { status: 200, endpoint: instance_config[:azure_foundry_endpoint].to_s }
    )
  end

  def inference_call_count(callable:)
    callable.provider.call_count
  end

  # The production callable does all classification (base Llm error classes +
  # the Azure EndpointDeactivated / model-not-ready body layers).
  def normalize_dispatch_error(error:)
    build_callable(instance_config: instance_configs.first).normalize_dispatch_error(error: error)
  end

  # D17 production shape: dispatch errors arrive as Legion::Extensions::Llm
  # errors whose wrapped response is a Faraday::Response (ErrorMiddleware),
  # never a raw Faraday error with a Hash response.
  def instance_unavailable_error
    response = Faraday::Response.new(
      status: 503,
      body: '{"error": {"code": "EndpointDeactivated", "message": "endpoint deactivated"}}'
    )
    Legion::Extensions::Llm::ServiceUnavailableError.new(response, 'the server responded with status 503')
  end

  def overloaded_error
    response = Faraday::Response.new(status: 529, body: '{"error": "Server overloaded"}')
    Legion::Extensions::Llm::OverloadedError.new(response, 'the server responded with status 529')
  end

  def model_not_ready_error
    response = Faraday::Response.new(
      status: 503,
      body: '{"error": "Model not ready — deployment is warming up"}'
    )
    Legion::Extensions::Llm::ServiceUnavailableError.new(response, 'the server responded with status 503')
  end

  private

  # Production discovery actor used as the source of the real identity and
  # offering-draft helpers (no timer: the spec stub of Every has none, so
  # instances are inert until driven manually).
  def discovery_actor
    @discovery_actor ||= Legion::Extensions::Llm::AzureFoundry::Actor::DiscoveryRefresh.new
  end
end

RSpec.describe Legion::Extensions::Llm::AzureFoundry do
  let(:ssot_harness) { AzureFoundrySsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # --- Azure Foundry-specific identity ---

  describe 'instance identity' do
    it 'publishes the operator config name as the instance_id' do
      expect(ssot_harness.instance_id(instance_config: ssot_harness.instance_configs[0])).to eq('eastus-prod')
      expect(ssot_harness.instance_id(instance_config: ssot_harness.instance_configs[1])).to eq('westus-prod')
    end

    it 'keeps the derived host:port/ak:fingerprint as the secondary physical id' do
      config = ssot_harness.instance_configs[0]
      fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint(
        config[:azure_foundry_api_key]
      )
      host_port = 'eastus-prod.services.ai.azure.com:443'
      expect(ssot_harness.physical_id(instance_config: config)).to eq("#{host_port}/ak:#{fingerprint}")
    end

    it 'derives the physical id as host:port without API key' do
      config = { azure_foundry_endpoint: 'https://public.services.ai.azure.com',
                 azure_foundry_bearer_token: 'bearer-only' }
      expect(ssot_harness.physical_id(instance_config: config)).to eq('public.services.ai.azure.com:443')
    end

    it 'raises instead of falling back to a placeholder endpoint for the physical id' do
      expect do
        ssot_harness.physical_id(instance_config: { azure_foundry_api_key: 'ak' })
      end.to raise_error(ArgumentError, /azure_foundry_endpoint/)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    # The physical id is never the identity: two config names pointing at the
    # SAME endpoint stay distinct instances, and the fingerprint still
    # distinguishes same-name-different-credential diagnostics.
    it 'keeps two config names distinct against the same endpoint (no collapse)' do
      config_a = { name: 'apollo', azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
                   azure_foundry_api_key: 'ak-one' }
      config_b = { name: 'apollo-embed', azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
                   azure_foundry_api_key: 'ak-one' }
      expect(ssot_harness.instance_id(instance_config: config_a)).not_to eq(
        ssot_harness.instance_id(instance_config: config_b)
      )

      same_a = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: ssot_harness.instance_id(instance_config: config_a),
        physical_id: ssot_harness.physical_id(instance_config: config_a)
      )
      same_b = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: ssot_harness.instance_id(instance_config: config_b),
        physical_id: ssot_harness.physical_id(instance_config: config_b)
      )
      expect(same_a).not_to eq(same_b)
    end

    it 'distinguishes same-name keys against the same endpoint via the physical id fingerprint' do
      config_a = { name: 'eastus-prod', azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
                   azure_foundry_api_key: 'ak-one' }
      config_b = { name: 'eastus-prod', azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
                   azure_foundry_api_key: 'ak-two' }
      expect(ssot_harness.physical_id(instance_config: config_a))
        .not_to eq(ssot_harness.physical_id(instance_config: config_b))
    end

    it 'lowercases the host for normalized physical id comparison' do
      config_upper = { azure_foundry_endpoint: 'https://EastUS-Prod.Services.AI.Azure.COM',
                       azure_foundry_api_key: 'ak-1' }
      config_lower = { azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
                       azure_foundry_api_key: 'ak-1' }
      expect(ssot_harness.physical_id(instance_config: config_upper))
        .to eq(ssot_harness.physical_id(instance_config: config_lower))
    end
  end

  # --- Two deployments on same endpoint ---

  describe 'two deployments on same endpoint' do
    let(:config) do
      {
        name: 'eastus-prod',
        azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
        azure_foundry_api_key: 'ak-azure-eastus-prod-001',
        azure_foundry_surface: :model_inference,
        azure_foundry_deployments: [
          { deployment: 'gpt-4o-deployment', model: 'gpt-4o', usage_type: :inference },
          { deployment: 'embed-deployment', model: 'text-embedding-3-small', usage_type: :embedding }
        ]
      }
    end

    it 'creates separate offerings for each deployment on the same instance' do
      ctx = bring_up_instance(config)
      snapshot = registry.snapshot
      offerings = snapshot.offerings_for(instance_key: ctx[:key])
      expect(offerings.size).to eq(2)
      models = offerings.map(&:model).sort
      expect(models).to eq(%w[gpt-4o text-embedding-3-small])
    end

    it 'creates separate lanes per deployment per supported operation' do
      ctx = bring_up_instance(config)
      snapshot = registry.snapshot
      lanes = snapshot.lanes_for(instance_key: ctx[:key])
      expect(lanes.size).to be >= 2
    end
  end

  # --- Same deployment on two endpoints ---

  describe 'same deployment on two endpoints' do
    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end
  end

  # --- Operation evidence ---

  describe 'operation evidence controls' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud) }
    let(:offering) { drafts.first }

    it 'marks chat as supported' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks stream_chat as supported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks embed as unsupported for inference deployments' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'marks image/transcribe/translate/speak/moderate as unsupported' do
      %i[image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end

    it 'marks count_tokens as unsupported (Azure has no portable endpoint)' do
      expect(offering.operation_evidence[:count_tokens].status).to eq(:unsupported)
    end

    it 'uses :provider_implementation source for supported/unsupported operations' do
      %i[chat stream_chat embed image transcribe translate speak moderate count_tokens].each do |op|
        expect(offering.operation_evidence[op].source).to eq(:provider_implementation),
                                                          "expected #{op} source to be :provider_implementation"
      end
    end
  end

  # --- Authoritative operation evidence: embedding deployments ---

  describe 'embedding deployment operation evidence' do
    let(:embed_config) do
      {
        name: 'eastus-prod',
        azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com',
        azure_foundry_api_key: 'ak-azure-eastus-prod-001',
        azure_foundry_surface: :model_inference,
        azure_foundry_deployments: [
          { deployment: 'embed-deployment', model: 'text-embedding-3-small', usage_type: :embedding }
        ]
      }
    end
    let(:embed_offering) { ssot_harness.build_offering_drafts(instance_config: embed_config, tier: :cloud).first }

    it 'publishes chat as :unsupported so a plain chat request cannot misroute to the embedding deployment' do
      expect(embed_offering.operation_evidence[:chat].status).to eq(:unsupported)
      expect(embed_offering.operation_evidence[:chat].source).to eq(:provider_implementation)
    end

    it 'publishes stream_chat as :unsupported' do
      expect(embed_offering.operation_evidence[:stream_chat].status).to eq(:unsupported)
    end

    it 'publishes embed as :supported' do
      expect(embed_offering.operation_evidence[:embed].status).to eq(:supported)
    end

    it 'publishes the embedding capability as :supported' do
      expect(embed_offering.capability_evidence[:embedding].status).to eq(:supported)
    end
  end

  # --- Startup gating ---

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) { identity_key_for(config) }
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    def inst_id = key.instance_id

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: inst_id, callable: callable, probe_request_handle: coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: inst_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      publisher.readiness_failed(instance_id: inst_id, probe_token: probe,
                                 reason: 'Azure Foundry health connection failed')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: inst_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # --- Readiness probe lifecycle ---

  describe 'readiness probe lifecycle' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) { identity_key_for(config) }
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    def inst_id = key.instance_id

    def activate_instance
      token = publisher.claim_instance(instance_id: inst_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    it 'rejects a stale probe started before a newer one that reported failure' do
      token = activate_instance

      stale_probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      fresh_probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)

      publisher.readiness_failed(instance_id: inst_id, probe_token: fresh_probe, reason: 'server down')

      result = publisher.readiness_succeeded(instance_id: inst_id, probe_token: stale_probe)
      expect(result.applied).to be(false)
      expect(result.reason).to eq(:stale_probe)
    end

    it 'recovers an unavailable instance after a valid probe succeeds' do
      token = activate_instance

      registry.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'connection refused'
      )
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:unavailable)

      new_probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      publisher.readiness_succeeded(instance_id: inst_id, probe_token: new_probe)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
    end
  end

  # --- Instance-unavailable isolation ---

  describe 'instance-unavailable isolation' do
    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to eastus-prod'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    # §8: ConnectionFailed is request-local — the callable returns
    # :connection_failure, never :instance_unavailable. Only an explicit
    # EndpointDeactivated body promotes to instance_unavailable.
    it 'normalizes connection failure as connection_failure on the callable (not instance_unavailable)' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused - eastus-prod.services.ai.azure.com:443')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'normalizes an Llm 503 as provider_error, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(
        error: Legion::Extensions::Llm::ServiceUnavailableError.new('503 service unavailable')
      )
      expect(outcome.kind).to eq(:provider_error)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    # D17: the production error shape (Llm error wrapping a Faraday::Response)
    # is what reaches the callable from ErrorMiddleware — the explicit
    # EndpointDeactivated body is read from that wrapped response.
    it 'promotes an Llm ServiceUnavailableError with an EndpointDeactivated body to instance_unavailable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    # D8: a raw Faraday error (connection-level path) carries its response as a
    # Faraday::Env, not a Hash — body detection must handle that real shape.
    it 'reads the EndpointDeactivated body from a raw Faraday error (Env response, not a Hash)' do
      env = Faraday::Env.new
      env.status = 503
      env.body = '{"error": {"code": "EndpointDeactivated", "message": "endpoint deactivated"}}'
      error = Faraday::ServerError.new('the server responded with status 503', env)
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:instance_unavailable)
    end
  end

  # --- Error classification (production error shapes) ---

  describe 'error classification' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0]) }

    def llm_error(klass, status, body)
      response = Faraday::Response.new(status: status, body: body)
      klass.new(response, "the server responded with status #{status}")
    end

    it 'classifies connection failure as connection_failure on the callable' do
      outcome = callable.normalize_dispatch_error(error: Faraday::ConnectionFailed.new('Connection refused'))
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      outcome = callable.normalize_dispatch_error(error: Faraday::TimeoutError.new('Net::ReadTimeout'))
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies generic errors as provider_error on the callable' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('unexpected failure'))
      expect(outcome.kind).to eq(:provider_error)
    end

    it 'classifies 401 as authentication on the callable' do
      outcome = callable.normalize_dispatch_error(error: llm_error(Legion::Extensions::Llm::UnauthorizedError, 401, ''))
      expect(outcome.kind).to eq(:authentication)
    end

    it 'classifies 403 as authorization on the callable' do
      outcome = callable.normalize_dispatch_error(error: llm_error(Legion::Extensions::Llm::ForbiddenError, 403, ''))
      expect(outcome.kind).to eq(:authorization)
    end

    it 'classifies a 404 as model_missing on the callable (unknown deployment)' do
      outcome = callable.normalize_dispatch_error(error: llm_error(Legion::Extensions::Llm::Error, 404, ''))
      expect(outcome.kind).to eq(:model_missing)
    end

    it 'classifies 429 as rate_limited on the callable' do
      outcome = callable.normalize_dispatch_error(error: llm_error(Legion::Extensions::Llm::RateLimitError, 429, ''))
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 529 as overloaded on the callable' do
      outcome = callable.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'classifies a model-not-ready 503 body as model_not_ready (request-local)' do
      outcome = callable.normalize_dispatch_error(error: ssot_harness.model_not_ready_error)
      expect(outcome.kind).to eq(:model_not_ready)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'never returns instance_unavailable from the callable for any plain server error' do
      [500, 502, 503, 504, 529].each do |status|
        error = case status
                when 529 then Legion::Extensions::Llm::OverloadedError
                else Legion::Extensions::Llm::ServiceUnavailableError
                end
        outcome = callable.normalize_dispatch_error(error: llm_error(error, status, ''))
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # --- Quota domain ---

  describe 'quota domain safety' do
    it 'declares deployment-scoped quota_domains on offerings' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)

      drafts.each do |draft|
        expect(draft.quota_domains).not_to be_empty,
                                           'Azure Foundry offerings must declare deployment-scoped quota_domains'
        draft.quota_domains.each_value do |domain|
          expect(domain).to match(/\Aazure:deployment:/)
        end
      end
    end
  end

  # --- Exact fleet execution ---

  describe 'exact fleet worker execution contract' do
    let(:config) { ssot_harness.instance_configs[0] }

    def activate_offering
      ctx = bring_up_instance(config)
      offering = registry.snapshot.offerings_for(instance_key: ctx[:key]).first
      { publisher: ctx[:publisher], token: ctx[:token], offering:, callable: ctx[:callable], key: ctx[:key] }
    end

    before do
      allow(Legion::Extensions::Llm::Fleet::WorkerExecution).to receive_messages(
        validate_identity!: true,
        validate_idempotency!: nil
      )
    end

    it 'rejects a mismatched offering_id' do
      ctx = activate_offering
      envelope = mismatched_offering_id_envelope(ctx: ctx)
      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects an unsupported operation' do
      ctx = activate_offering
      envelope = unsupported_operation_envelope(ctx: ctx)
      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects a mismatched model' do
      ctx = activate_offering
      envelope = mismatched_model_envelope(ctx: ctx)
      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects an unavailable instance' do
      ctx = activate_offering
      registry.dispatch_instance_unavailable(
        instance_key: ctx[:key], publisher_token_id: ctx[:token].publisher_token_id, reason: 'server down'
      )
      envelope = available_offering_envelope(ctx: ctx)
      expect do
        Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    private

    def fleet_base_envelope(ctx:)
      {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: ctx[:offering].offering_id,
        provider: 'azure_foundry',
        provider_instance: ctx[:key].instance_id,
        model: ctx[:offering].model,
        operation: 'chat',
        params: { messages: [] }
      }
    end

    def mismatched_offering_id_envelope(ctx:)
      fleet_base_envelope(ctx: ctx).merge(
        offering_id: 'off:v1:0000000000000000000000000000000000000000000000000000000000000000'
      )
    end

    def unsupported_operation_envelope(ctx:)
      fleet_base_envelope(ctx: ctx).merge(operation: 'image', params: {})
    end

    def mismatched_model_envelope(ctx:)
      fleet_base_envelope(ctx: ctx).merge(model: 'some-other-model/v1')
    end

    def available_offering_envelope(ctx:)
      fleet_base_envelope(ctx: ctx)
    end
  end

  # --- Dependency isolation ---

  describe 'dependency isolation' do
    it 'does not require Legion::LLM (no reverse dependency on top-level llm module)' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/azure_foundry/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'AzureFoundryCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # --- No default model/provider ---

  describe 'no default model or provider' do
    it 'accepts "default" as an operator instance label' do
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: 'default'
      )

      expect(key.provider_family).to eq(:azure_foundry)
      expect(key.instance_id).to eq('default')
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :azure_foundry, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'does not define a DEFAULT_PROVIDER constant' do
      expect(described_class.const_defined?(:DEFAULT_PROVIDER, false)).to be(false)
    end
  end

  # --- AzureFoundryCallable direct contract ---

  describe Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to the fleet dispatch operations' do
      expect(callable).to respond_to(:chat)
      expect(callable).to respond_to(:stream_chat)
      expect(callable).to respond_to(:embed)
      expect(callable).to respond_to(:count_tokens)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'closes the wrapped provider on disconnect' do
      provider = instance_spy(Legion::Extensions::Llm::AzureFoundry::Provider)
      subject_callable = described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider:
      )
      subject_callable.disconnect
      expect(provider).to have_received(:disconnect)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'keeps the reason bounded' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('x' * 1000))
      expect(outcome.reason.length).to be <= 1024
    end

    describe 'fleet raw-string model (D15)' do
      # The fleet passes model: as the offering's raw model id (String). The
      # chat/stream_chat render path calls model.id (stock
      # OpenAICompatible#render_payload), so the callable must hand the
      # provider a Model::Info there; embed/count_tokens are string-tolerant
      # (Provider#model_id accepts the value verbatim), so wrapping them would
      # serialize a Data object into the wire payload or response.
      let(:capturing) { ModelCapturingAzureFoundryProvider.new }
      let(:capturing_callable) do
        described_class.new(
          instance_cfg: ssot_harness.instance_configs[0],
          logger: Logger.new(File::NULL),
          provider: capturing
        )
      end

      it 'wraps a raw string model into a Model::Info for chat' do
        capturing_callable.chat(messages: [{ role: 'user', content: 'hi' }], model: 'gpt-4o')

        model = capturing.received_models[:chat]
        expect(model).to be_a(Legion::Extensions::Llm::Model::Info)
        expect(model.id).to eq('gpt-4o')
        expect(model.provider).to eq(:azure_foundry)
      end

      it 'wraps a raw string model into a Model::Info for stream_chat' do
        capturing_callable.stream_chat(messages: [], model: 'gpt-4o')

        model = capturing.received_models[:stream_chat]
        expect(model).to be_a(Legion::Extensions::Llm::Model::Info)
        expect(model.id).to eq('gpt-4o')
      end

      it 'forwards the stream block to the provider' do
        streamed = []
        block_capturing = Class.new do
          define_method(:stream) do |**, &block|
            block.call({ delta: 'chunk' })
          end
        end.new
        block_callable = described_class.new(
          instance_cfg: ssot_harness.instance_configs[0],
          logger: Logger.new(File::NULL),
          provider: block_capturing
        )
        block_callable.stream_chat(messages: [], model: 'gpt-4o') { |chunk| streamed << chunk }
        expect(streamed).to eq([{ delta: 'chunk' }])
      end

      it 'passes a Model::Info through unchanged for chat' do
        info = Legion::Extensions::Llm::Model::Info.new(id: 'gpt-4o', provider: :azure_foundry)
        capturing_callable.chat(messages: [], model: info)
        expect(capturing.received_models[:chat]).to equal(info)
      end

      it 'passes the raw model verbatim for embed and count_tokens' do
        capturing_callable.embed(text: 'hello', model: 'text-embedding-3-small')
        capturing_callable.count_tokens(messages: [], model: 'gpt-4o')

        expect(capturing.received_models[:embed]).to eq('text-embedding-3-small')
        expect(capturing.received_models[:count_tokens]).to eq('gpt-4o')
      end
    end
  end

  # --- OfferingDraft structure ---

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each do |draft|
        actual_ops = draft.operation_evidence.keys.sort
        expect(actual_ops).to eq(expected_ops)
      end
    end

    it 'sets publication_source to :provider_static_catalog' do
      drafts.each do |draft|
        expect(draft.publication_source).to eq(:provider_static_catalog)
      end
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key do |mkey|
          normalized = mkey.to_s.downcase.gsub(/[^a-z0-9]/, '')
          expect(normalized).not_to include('credential')
          expect(normalized).not_to include('secret')
          expect(normalized).not_to include('apikey')
        end
      end
    end

    it 'keeps provider_native_key (deployment) distinct from model' do
      drafts.each do |draft|
        expect(draft.provider_native_key).to eq('gpt-4o-deployment')
        expect(draft.model).to eq('gpt-4o')
      end
    end
  end

  # --- ReadinessResult contract ---

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end

  private

  # Identity = config name; the derived endpoint id rides the secondary
  # physical-id field.
  def identity_key_for(config)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry,
      instance_id: ssot_harness.instance_id(instance_config: config),
      physical_id: ssot_harness.physical_id(instance_config: config)
    )
  end

  # Claims and activates one instance through the public Publisher API using
  # the production callable + the actor's real offering builders.
  def bring_up_instance(config, tier: :cloud)
    publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
    inst_id = ssot_harness.instance_id(instance_config: config)
    key = identity_key_for(config)
    callable = ssot_harness.build_callable(instance_config: config)
    coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
      instance_key: key, enqueue: ->(**) { true }
    )
    token = publisher.claim_instance(instance_id: inst_id, callable: callable,
                                     probe_request_handle: coordinator)
    probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
    drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
    publisher.activate_instance_snapshot(
      instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
    )
    { publisher:, key:, callable:, token:, drafts: }
  end
end
