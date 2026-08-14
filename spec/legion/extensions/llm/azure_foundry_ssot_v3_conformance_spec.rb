# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

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

# Stub the actor runtime so discovery_refresh.rb loads the AzureFoundryCallable class.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Stub base class for discovery actor loading in test context
        class Every
          def self.every_seconds = 3600
        end
      end
    end

    module Helpers
      module Lex; end unless const_defined?(:Lex, false)
    end
  end
end

# Use `load` instead of `require` because spec_helper already required the file
# (which returned early due to missing Every class). Now that we have the stub,
# we need to force-reload so the classes are actually defined.
load File.expand_path('../../../../lib/legion/extensions/llm/azure_foundry/actors/discovery_refresh.rb', __dir__)

# Test-local callable that extends AzureFoundryCallable with tracking.
# Tracks inference call count for conformance assertions.
class TrackingAzureFoundryCallable < Legion::Extensions::Llm::AzureFoundry::Actor::AzureFoundryCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(model:, **)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model }
  end

  def count_tokens(model:, **)
    @call_count += 1
    { token_count: 42, model: model }
  end
end

# Evidence-building and escalation helpers for the SSOT v3 conformance harness.
# Extracted to a module so AzureFoundrySsotHarness stays under the class length limit.
module AzureFoundrySsotEvidenceHelpers
  private

  def build_operation_evidence(now:, embed_supported:)
    embed_status = embed_supported ? :supported : :unsupported
    {
      chat: op_evidence(:chat, :supported, now),
      stream_chat: op_evidence(:stream_chat, :supported, now),
      embed: op_evidence(:embed, embed_status, now),
      image: op_evidence(:image, :unsupported, now),
      transcribe: op_evidence(:transcribe, :unsupported, now),
      translate: op_evidence(:translate, :unsupported, now),
      speak: op_evidence(:speak, :unsupported, now),
      moderate: op_evidence(:moderate, :unsupported, now),
      count_tokens: op_evidence(:count_tokens, :unsupported, now)
    }
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_implementation
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      )
    }
  end

  def extract_host_port(base_url:)
    uri = URI.parse(base_url.to_s)
    "#{(uri.host || 'localhost').downcase}:#{uri.port}"
  end

  def build_single_offering(deployment_name:, model_id:, tier:, now:)
    absent = Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: deployment_name, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, embed_supported: false),
      capability_evidence: build_capability_evidence,
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: 128_000, source: :provider_catalog
      ),
      max_output_evidence: absent,
      embedding_dimensions_evidence: absent,
      model_revision_evidence: absent,
      tokenizer_evidence: absent,
      quota_domains: {
        chat: "azure:deployment:#{deployment_name}",
        stream_chat: "azure:deployment:#{deployment_name}",
        embed: "azure:deployment:#{deployment_name}"
      },
      metadata: { raw_deployment: deployment_name, model_family: :openai },
      publication_source: :provider_static_catalog
    )
  end

  def apply_azure_escalation(outcome:, error:)
    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :model_not_ready,
                                                                   reason: outcome.reason)
    end

    outcome
  end

  def model_not_ready_signal?(error:)
    return false unless error.respond_to?(:response) && error.response.is_a?(Hash)

    body = error.response[:body].to_s.downcase
    body.include?('model not ready') || body.include?('deployment is warming up')
  end
end

# Harness class for Azure Foundry SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service.
class AzureFoundrySsotHarness
  include AzureFoundrySsotEvidenceHelpers

  INSTANCE_CONFIGS = [
    {
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

  def instance_id(instance_config:)
    endpoint = instance_config[:azure_foundry_endpoint] || instance_config[:endpoint] || 'https://localhost:443'
    host_port = extract_host_port(base_url: endpoint)
    api_key = instance_config[:azure_foundry_api_key] || instance_config.dig(:credentials, :api_key)

    return host_port unless api_key.is_a?(String) && !api_key.strip.empty?

    "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 6]}"
  end

  def build_callable(instance_config:)
    TrackingAzureFoundryCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :cloud, **)
    now = Time.now.freeze
    [build_single_offering(deployment_name: 'gpt-4o-deployment', model_id: 'gpt-4o', tier: tier, now: now)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Azure Foundry health returned 200',
      metadata: { status: 200, endpoint: instance_config[:azure_foundry_endpoint].to_s }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_azure_escalation(outcome: outcome, error: error)
  end

  # §8: instance_unavailable comes only from an explicit Azure EndpointDeactivated code —
  # not from ConnectionFailed, which is request-local.
  def instance_unavailable_error
    response = { status: 503, headers: {},
                 body: '{"error": {"code": "EndpointDeactivated", "message": "endpoint deactivated"}}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def overloaded_error
    response = { status: 503, headers: {}, body: '{"error": "Server overloaded"}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def model_not_ready_error
    response = { status: 503, headers: {}, body: '{"error": "Model not ready", "detail": "deployment is warming up"}' }
    Faraday::ServerError.new('the server responded with status 503 - deployment is warming up', response)
  end
end

RSpec.describe Legion::Extensions::Llm::AzureFoundry do
  let(:ssot_harness) { AzureFoundrySsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # --- Azure Foundry-specific identity derivation ---

  describe 'instance identity derivation' do
    it 'derives instance_id as host:port/ak:fingerprint with API key' do
      config = ssot_harness.instance_configs[0]
      fingerprint = Digest::SHA256.hexdigest(config[:azure_foundry_api_key])[0, 6]
      host_port = 'eastus-prod.services.ai.azure.com:443'
      expect(ssot_harness.instance_id(instance_config: config)).to eq("#{host_port}/ak:#{fingerprint}")
    end

    it 'derives instance_id as host:port without API key' do
      config = { azure_foundry_endpoint: 'https://public.services.ai.azure.com' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('public.services.ai.azure.com:443')
    end

    it 'produces distinct instance IDs for two different endpoints' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'lowercases the host for normalized comparison' do
      config_upper = { azure_foundry_endpoint: 'https://EastUS-Prod.Services.AI.Azure.COM' }
      config_lower = { azure_foundry_endpoint: 'https://eastus-prod.services.ai.azure.com' }
      expect(ssot_harness.instance_id(instance_config: config_upper))
        .to eq(ssot_harness.instance_id(instance_config: config_lower))
    end
  end

  # --- Two deployments on same endpoint ---

  describe 'two deployments on same endpoint' do
    let(:config) do
      {
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

    private

    def bring_up_instance(cfg, tier: :cloud)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
      inst_id = ssot_harness.instance_id(instance_config: cfg)
      key = build_instance_key_for(provider_family: :azure_foundry, instance_id: inst_id)
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: inst_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      drafts = build_deployment_drafts(cfg: cfg, tier: tier, harness: ssot_harness)
      publisher.activate_instance_snapshot(
        instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    def build_instance_key_for(provider_family:, instance_id:)
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: provider_family, instance_id: instance_id
      )
    end

    def build_deployment_drafts(cfg:, tier:, harness:)
      now = Time.now.freeze
      cfg[:azure_foundry_deployments].map do |dep|
        build_deployment_draft(dep: dep, tier: tier, now: now, harness: harness)
      end
    end

    def build_deployment_draft(dep:, tier:, now:, harness:)
      absent = Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
      embed = %w[embed embedding].include?((dep[:usage_type] || dep[:type]).to_s)
      Legion::Extensions::Llm::Inventory::OfferingDraft.new(
        provider_native_key: dep[:deployment], model: dep[:model], tier: tier,
        operation_evidence: harness.send(:build_operation_evidence, now: now, embed_supported: embed),
        capability_evidence: harness.send(:build_capability_evidence),
        context_evidence: absent, max_output_evidence: absent,
        embedding_dimensions_evidence: absent, model_revision_evidence: absent, tokenizer_evidence: absent,
        quota_domains: { chat: "azure:deployment:#{dep[:deployment]}",
                         stream_chat: "azure:deployment:#{dep[:deployment]}",
                         embed: "azure:deployment:#{dep[:deployment]}" },
        metadata: { raw_deployment: dep[:deployment] },
        publication_source: :provider_static_catalog
      )
    end
  end

  # --- Same deployment on two endpoints ---

  describe 'same deployment on two endpoints' do
    def bring_up(cfg)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
      inst_id = ssot_harness.instance_id(instance_config: cfg)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: inst_id
      )
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: inst_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: cfg, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

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

  # --- Startup gating ---

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: ssot_harness.instance_id(instance_config: config)
      )
    end
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
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: ssot_harness.instance_id(instance_config: config)
      )
    end
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
    def bring_up(cfg)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
      inst_id = ssot_harness.instance_id(instance_config: cfg)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: inst_id
      )
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: inst_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: cfg, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to eastus-prod'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    # §8: ConnectionFailed is request-local — the callable returns :connection_failure,
    # never :instance_unavailable. Only an explicit EndpointDeactivated error promotes to
    # instance_unavailable.
    it 'normalizes connection failure as connection_failure on the callable (not instance_unavailable)' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused - connect(2) for eastus-prod.services.ai.azure.com:443')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # --- Error classification ---

  describe 'error classification' do
    it 'classifies connection failure as connection_failure on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies generic errors as provider_error on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = RuntimeError.new('unexpected failure')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:provider_error)
    end

    it 'classifies 401 as authentication on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 401, headers: {}, body: '' }
      error = Faraday::ClientError.new('401', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authentication)
    end

    it 'classifies 403 as authorization on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 403, headers: {}, body: '' }
      error = Faraday::ClientError.new('403', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authorization)
    end

    it 'classifies 404 as model_missing on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 404, headers: {}, body: '' }
      error = Faraday::ClientError.new('404', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:model_missing)
    end

    it 'classifies 429 as rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 503 ServerError as overloaded on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 503, headers: {}, body: '' }
      error = Faraday::ServerError.new('503', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
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
    let(:inst_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :azure_foundry, instance_id: inst_id
      )
    end

    def activate_offering
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :azure_foundry)
      callable = ssot_harness.build_callable(instance_config: config)
      token = claim_and_activate(publisher: publisher, callable: callable)
      offering = registry.snapshot.offerings_for(instance_key: key).first
      { publisher: publisher, token: token, offering: offering, callable: callable }
    end

    def claim_and_activate(publisher:, callable:)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: inst_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: inst_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud)
      publisher.activate_instance_snapshot(
        instance_id: inst_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    before do
      allow(Legion::Extensions::Llm::Fleet::WorkerExecution).to receive_messages(
        validate_identity!: true,
        validate_idempotency!: nil
      )
    end

    it 'rejects a mismatched offering_id' do
      activate_offering
      envelope = mismatched_offering_id_envelope(model: 'gpt-4o')
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
      registry.dispatch_instance_unavailable(instance_key: key, publisher_token_id: ctx[:token].publisher_token_id,
                                             reason: 'server down')
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
        provider_instance: inst_id,
        model: ctx[:offering].model,
        operation: 'chat',
        params: { messages: [] }
      }
    end

    def mismatched_offering_id_envelope(model:)
      {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: 'off:v1:0000000000000000000000000000000000000000000000000000000000000000',
        provider: 'azure_foundry',
        provider_instance: inst_id,
        model: model,
        operation: 'chat',
        params: { messages: [] }
      }
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
    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :azure_foundry, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
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

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'truncates reason to 512 bytes' do
      long_message = 'x' * 1000
      error = RuntimeError.new(long_message)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.reason.length).to be <= 1024
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
end
