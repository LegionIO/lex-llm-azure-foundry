# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

# The runner is NOT on the default require path outside the daemon — explicit.
require 'legion/extensions/llm/azure_foundry/runners/discovery'

# Runner-level discovery spec for the Azure Foundry-specific slice ONLY. The
# generic reconcile / claim / activate / probe / replace / churn /
# weight-publication / dormant-tracking pipeline is mixed in from the shared
# Discovery::Pipeline and is proven at the shared owner — this spec drives
# `runner.refresh` and pins what ONLY this provider decides: the surface-aware
# catalog path, the api-key + bearer auth, the catalog fetch (CatalogFetchFailure
# on a bad transport), the host:port/ak:<fingerprint> physical id, the
# config-name identity, the weight-free draft (weight is computed by the shared
# WeightReconciler from live settings AT publish, asserted here on the
# published lane), and the D14 settings health write-back keyed by config name.
RSpec.describe Legion::Extensions::Llm::AzureFoundry::Runners::Discovery do
  # let, not subject: the cop forbids stubbing the subject, and these specs
  # must stub the runner's fetch/health seams to keep the network out.
  let(:runner) { described_class }

  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  # The operator's configured instances in the RAW settings shape the
  # production AzureFoundry.discover_instances normalizes — the pipeline's
  # single claimable source.
  let(:instances_cfg) do
    {
      eastus: { endpoint: 'https://eastus.services.ai.azure.com', api_key: 'ak-spec-eastus', tier: :cloud },
      westus: { endpoint: 'https://westus.services.ai.azure.com', api_key: 'ak-spec-westus', tier: :cloud }
    }
  end
  let(:catalog) do
    [
      { 'id' => 'gpt-4o-deployment', 'model_name' => 'gpt-4o', 'context_window' => 128_000 },
      { 'id' => 'embed-deployment', 'model_name' => 'text-embedding-3-small' }
    ]
  end
  let(:ready) do
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true, reason: 'Azure Foundry health returned 200', metadata: { status: 200 }
    )
  end

  def settings_tree = Legion::Settings[:extensions][:llm][:azure_foundry]

  # One genuine settings tree drives both sides: the production
  # discover_instances reads the provider credentials through
  # CredentialSources, and the D14 health write-back reads
  # settings[:instances][<name>] — both resolve to this hash.
  def configure_settings(instances)
    Legion::Settings[:extensions][:llm] = { azure_foundry: { instances: instances } }
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(settings_tree)
  end

  # The production-normalized instance config (endpoint / api_key promoted to
  # azure_foundry_* keys) for one configured instance name.
  def discover_cfg(name)
    Legion::Extensions::Llm::AzureFoundry.discover_instances.fetch(name.to_sym)
  end

  # Identity = the operator's config NAME; the derived endpoint id rides the
  # secondary physical-id field.
  def key(name)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry,
      instance_id: name.to_s,
      physical_id: runner.derive_physical_id(instance_cfg: discover_cfg(name))
    )
  end

  before do
    registry.reset!
    runner.reset_state!
    configure_settings(instances_cfg)
    allow(runner).to receive_messages(fetch_raw_models: catalog, check_health: ready)
  end

  describe 'claim and activation' do
    it 'claims, probes, and activates every configured instance on the first tick' do
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key(:eastus)).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key(:eastus)).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: key(:westus)).availability.state).to eq(:available)
    end

    it 'publishes the config name as instance_id with the derived endpoint id as the physical id' do
      runner.refresh

      record = registry.snapshot.instance(instance_key: key(:eastus))
      expect(record.instance_key.instance_id).to eq('eastus')
      fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint('ak-spec-eastus')
      expect(record.instance_key.physical_id).to eq("eastus.services.ai.azure.com:443/ak:#{fingerprint}")
    end

    it 'publishes one lane per catalog model per supported operation' do
      runner.refresh

      lanes = registry.snapshot.lanes_for(instance_key: key(:eastus))
      expect(lanes.map { |lane| [lane.operation, lane.model] }.sort)
        .to eq([[:chat, 'gpt-4o-deployment'], [:embed, 'embed-deployment']])
    end

    # Skip is enforced upstream — discover_instances is the single claimable
    # source, so a credential-less or disabled instance is never claimable.
    it 'never claims a credential-less or disabled instance' do
      configure_settings(
        eastus: instances_cfg[:eastus],
        naked: { endpoint: 'https://naked.services.ai.azure.com', tier: :cloud },
        disabled: { endpoint: 'https://disabled.services.ai.azure.com', api_key: 'ak-x', enabled: false }
      )

      expect(Legion::Extensions::Llm::AzureFoundry.discover_instances.keys).to eq([:eastus])

      runner.refresh

      expect(registry.snapshot.each_instance.map { |record| record.instance_key.instance_id })
        .to eq(['eastus'])
    end
  end

  describe 'catalog connection' do
    def catalog_connection(instance_cfg)
      runner.send(:build_connection,
                  base_url: runner.catalog_base_url(instance_cfg: instance_cfg),
                  instance_cfg: instance_cfg, timeout: 10, open_timeout: 5)
    end

    it 'sends the api-key header when an api key is configured' do
      cfg = { azure_foundry_endpoint: 'https://eastus.services.ai.azure.com', azure_foundry_api_key: 'ak-1' }

      expect(catalog_connection(cfg).headers['api-key']).to eq('ak-1')
      expect(catalog_connection(cfg).headers['Authorization']).to be_nil
    end

    it 'sends the bearer Authorization header when a bearer token is configured (not only api-key)' do
      cfg = { azure_foundry_endpoint: 'https://eastus.services.ai.azure.com', azure_foundry_bearer_token: 'bt-1' }

      expect(catalog_connection(cfg).headers['Authorization']).to eq('Bearer bt-1')
      expect(catalog_connection(cfg).headers['api-key']).to be_nil
    end

    it 'uses the surface catalog path: models/info on model_inference, models on openai_v1' do
      inference = { azure_foundry_endpoint: 'https://e.example', azure_foundry_api_key: 'ak',
                    azure_foundry_surface: :model_inference }
      openai = { azure_foundry_endpoint: 'https://e.example', azure_foundry_api_key: 'ak',
                 azure_foundry_surface: :openai_v1 }

      expect(runner.catalog_path(instance_cfg: inference)).to eq('models/info?api-version=2024-05-01-preview')
      expect(runner.catalog_path(instance_cfg: openai)).to eq('models')
      expect(runner.catalog_base_url(instance_cfg: openai)).to eq('https://e.example/openai/v1')
    end

    it 'raises CatalogFetchFailure on a non-200 catalog response' do
      cfg = { azure_foundry_endpoint: 'https://e.example', azure_foundry_api_key: 'ak' }
      allow(runner).to receive(:fetch_raw_models).and_call_original
      response = Struct.new(:status, :body).new(500, '{"error": "boom"}')
      conn = instance_double(Faraday::Connection, get: response)
      allow(runner).to receive(:build_connection).and_return(conn)

      expect { runner.fetch_raw_models(instance_cfg: cfg) }
        .to raise_error(described_class::CatalogFetchFailure, /HTTP 500/)
    end

    it 'wraps a transport failure as CatalogFetchFailure when building offerings (never an empty catalog)' do
      allow(runner).to receive(:fetch_raw_models).and_raise(Faraday::ConnectionFailed, 'connection refused')

      expect { runner.build_offerings(instance_cfg: discover_cfg(:eastus), instance_key: key(:eastus)) }
        .to raise_error(described_class::CatalogFetchFailure, /Faraday::ConnectionFailed/)
    end
  end

  # The readiness probe is the SAME non-inference catalog GET — never a
  # chat/embed call.
  describe 'readiness' do
    it 'probes readiness with the catalog GET (no inference)' do
      cfg = { azure_foundry_endpoint: 'https://e.example', azure_foundry_api_key: 'ak' }
      allow(runner).to receive(:check_health).and_call_original
      conn = instance_double(Faraday::Connection)
      allow(runner).to receive(:build_connection).and_return(conn)
      allow(conn).to receive(:get).with('models/info?api-version=2024-05-01-preview')
                                  .and_return(Struct.new(:status, :body).new(200, '{}'))

      result = runner.check_health(instance_cfg: cfg)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(conn).to have_received(:get).with('models/info?api-version=2024-05-01-preview')
    end

    it 'reports a non-200 catalog GET as not ready with the status in the reason' do
      cfg = { azure_foundry_endpoint: 'https://e.example', azure_foundry_api_key: 'ak' }
      allow(runner).to receive(:check_health).and_call_original
      conn = instance_double(Faraday::Connection,
                             get: Struct.new(:status, :body).new(503, '{"error": "warming up"}'))
      allow(runner).to receive(:build_connection).and_return(conn)

      result = runner.check_health(instance_cfg: cfg)

      expect(result.ready?).to be(false)
      expect(result.reason).to eq('Azure Foundry health returned 503')
    end
  end

  # D14: the display health hash is written to the GENUINE settings tree
  # (Legion::Settings[:extensions][:llm][:azure_foundry]), keyed by the
  # operator's config name — never the derived physical id.
  describe 'settings display health (D14)' do
    it 'writes the 5-key health hash plus capabilities after the commit' do
      runner.refresh

      health = settings_tree.dig(:instances, :eastus, :health)
      expect(health.keys).to match_array(%i[state reason observed_at last_probe_outcome source])
      expect(health).to include(state: :available, source: :startup_readiness, last_probe_outcome: :success)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)

      expect(settings_tree.dig(:instances, :eastus, :capabilities)).to include(:completion, :streaming)
    end

    it 'keys the health hash by the config name, never the derived physical id' do
      runner.refresh

      physical_id = runner.derive_physical_id(instance_cfg: discover_cfg(:eastus))
      expect(settings_tree[:instances].keys).to contain_exactly(:eastus, :westus)
      expect(settings_tree[:instances].keys.map(&:to_s)).not_to include(physical_id)
    end

    it 'clears the health hash when the instance disappears from the claimable set' do
      eastus_key = key(:eastus)
      runner.refresh
      expect(settings_tree.dig(:instances, :eastus, :health)).not_to be_nil

      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ westus: discover_cfg(:westus) })
      runner.refresh

      expect(settings_tree.dig(:instances, :eastus, :health)).to be_nil
      expect(settings_tree.dig(:instances, :eastus, :capabilities)).to be_nil
      expect(registry.snapshot.instance(instance_key: eastus_key)).to be_nil
    end

    it 'clears settings health and releases the registry on shutdown' do
      runner.refresh

      runner.remove_all_instances

      expect(runner.states).to be_empty
      expect(settings_tree.dig(:instances, :eastus, :health)).to be_nil
      expect(settings_tree.dig(:instances, :eastus, :capabilities)).to be_nil
      expect(registry.snapshot.each_instance.to_a).to be_empty
    end
  end

  # D12: runtime state (publisher token, probe coordinator) lives in the
  # runner's process-local state — never in the settings tree.
  describe 'per-instance runtime state (D12)' do
    it 'keeps the publisher token and probe coordinator in the runner state, not settings' do
      runner.refresh

      state = runner.states.fetch('eastus')
      expect(state[:publisher_token]).to respond_to(:publisher_token_id)
      expect(state[:probe_coordinator]).to respond_to(:begin_probe)

      expect(settings_tree).not_to have_key(:publisher_token)
      expect(settings_tree).not_to have_key(:probe_coordinator)
    end
  end

  # WEIGHT IS NOT COMPUTED IN THE RUNNER. Drafts are built identity-weighted;
  # the shared WeightReconciler recomputes the pair from live settings at
  # publish. The provider-specific surface here is the settings shape this
  # provider's operator writes (instances.<name> / instances.<name>.models)
  # and the fact that the pair lands on the PUBLISHED LANE, never a draft.
  describe 'write-time lane weights' do
    let(:instances_cfg) do
      { eastus: { endpoint: 'https://eastus.services.ai.azure.com', api_key: 'ak-spec-eastus', tier: :cloud } }
    end

    def set_weights(tier: 100, provider: 100, instance: 100, model: nil)
      tree = settings_tree
      tree[:weight] = provider
      tree[:instances][:eastus][:weight] = instance
      tree[:instances][:eastus][:models] = { 'gpt-4o-deployment' => { weight: model } } unless model.nil?
      Legion::Settings.loader.settings[:llm] = { routing: { tier_weights: { cloud: tier } } }
    end

    def state = runner.states.fetch('eastus')

    def published_lane
      registry.snapshot.lanes_for(instance_key: key(:eastus)).find { |lane| lane.model == 'gpt-4o-deployment' }
    end

    around do |example|
      original_llm = Legion::Settings.loader.settings[:llm]
      example.run
    ensure
      Legion::Settings.loader.settings[:llm] = original_llm
    end

    it 'builds drafts identity-weighted — the runner computes NO weight' do
      set_weights(tier: 110, provider: 120, instance: 130, model: 140)
      cfg = discover_cfg(:eastus)

      draft = runner.send(:build_offering_draft, instance_cfg: cfg, instance_key: key(:eastus),
                                                 model_id: 'gpt-4o-deployment',
                                                 model_data: { 'id' => 'gpt-4o-deployment', 'model_name' => 'gpt-4o' })

      expect(draft.weight_inputs).to eq(tier: 100, provider: 100, instance: 100, model_or_offering: 100)
      expect(draft.base_weight).to eq(100_000_000)
    end

    it 'computes the lane weight from live settings at publish and asserts the pair on the published lane' do
      set_weights(tier: 110, provider: 120, instance: 130, model: 140)

      runner.refresh

      lane = published_lane
      expect(lane.weight_inputs).to eq(tier: 110, provider: 120, instance: 130, model_or_offering: 140)
      expect(lane.base_weight).to eq(240_240_000)
      cached = state[:offerings].find { |draft| draft.model == 'gpt-4o-deployment' }
      expect(cached.weight_inputs).to eq(lane.weight_inputs)
    end

    it 'stores zero as a disabling component on the published lane' do
      set_weights(instance: 0)

      runner.refresh

      expect(published_lane.weight_inputs[:instance]).to eq(0)
      expect(published_lane.base_weight).to eq(0)
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      runner.refresh
      publisher = runner.publisher
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |method, **kwargs|
        replacements << kwargs
        method.call(**kwargs)
      end

      set_weights(instance: 130)
      runner.refresh

      expect(replacements.length).to eq(1)
      expect(published_lane.weight_inputs[:instance]).to eq(130)
      expect(state[:sequence]).to eq(1)
    end

    it 'keeps the sequence stable across unchanged ordinary passes' do
      runner.refresh
      publisher = runner.publisher
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |method, **kwargs|
        replacements << kwargs
        method.call(**kwargs)
      end
      sequence = state[:sequence]

      10.times { runner.refresh }

      expect(replacements).to be_empty
      expect(state[:sequence]).to eq(sequence)
    end

    # A malformed weight (false) is a rejected operator input: the lane is
    # never published from it, and the pass retries cleanly once corrected.
    it 'leaves no published lane for malformed weights and re-activates once corrected' do
      set_weights(instance: false)

      runner.refresh

      expect(registry.snapshot.each_instance.to_a).to be_empty
      expect(registry.snapshot.lanes_for(instance_key: key(:eastus))).to be_empty
      expect(registry.snapshot.publication_status(instance_key: key(:eastus)).state).to eq(:initializing)
      expect(state[:published]).to be(false)

      set_weights(instance: 115)
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key(:eastus)).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key(:eastus)).state).to eq(:complete)
      expect(published_lane.weight_inputs[:instance]).to eq(115)
      expect(state[:published]).to be(true)
    end

    it 'logs the dormant weight once per disappearance' do
      logger = instance_double(Logger, info: nil)
      allow(runner).to receive(:log).and_return(logger)
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances).and_return({})
      settings_tree[:weight] = 120

      runner.refresh
      runner.refresh

      message = '[llm][azure_foundry] action=dormant_weight ' \
                'weight_key=[:azure_foundry, :provider] no_lane_published=true'
      expect(logger).to have_received(:info).with(message).once
    end
  end
end
