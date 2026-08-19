# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Actor::DiscoveryRefresh do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:actor) { described_class.new }
  let(:eastus_cfg) do
    {
      azure_foundry_endpoint: 'https://eastus.services.ai.azure.com',
      tier: :cloud,
      azure_foundry_api_key: 'ak-spec-eastus',
      azure_foundry_surface: :model_inference
    }
  end
  let(:westus_cfg) do
    {
      azure_foundry_endpoint: 'https://westus.services.ai.azure.com',
      tier: :cloud,
      azure_foundry_api_key: 'ak-spec-westus',
      azure_foundry_surface: :model_inference
    }
  end
  let(:catalog) do
    [{ 'id' => 'gpt-4o-deployment', 'model_name' => 'gpt-4o', 'context_window' => 128_000 }]
  end
  let(:readiness) do
    {
      ready: Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: true, reason: 'Azure Foundry health returned 200', metadata: { status: 200 }
      ),
      unready: Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: false, reason: 'Azure Foundry health connection failed',
        metadata: { error_class: 'Faraday::ConnectionFailed' }
      )
    }
  end

  before do
    registry.reset!
    allow(actor).to receive(:fetch_catalog_entries).and_return(catalog)
  end

  # Identity = the operator's config NAME; the derived endpoint id rides the
  # secondary physical-id field.
  def key_for(name, instance_cfg: nil)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry,
      instance_id: name.to_s,
      physical_id: instance_cfg && actor.send(:derive_physical_id, instance_cfg: instance_cfg)
    )
  end

  # ── D9: actor periodicity ───────────────────────────────────────────────────

  describe 'tick interval (time)' do
    it 'returns the registered discovery.interval_seconds (never nil)' do
      allow(actor).to receive(:settings).and_return({})
      expect(actor.time)
        .to eq(Legion::Extensions::Llm::AzureFoundry.default_settings.dig(:discovery, :interval_seconds))
    end

    it 'honors an operator override of the interval' do
      allow(actor).to receive(:settings).and_return({ discovery: { interval_seconds: 60 } })
      expect(actor.time).to eq(60)
    end

    it 'falls back to the registered default when the interval is missing or non-positive' do
      allow(actor).to receive(:settings).and_return({ discovery: { interval_seconds: nil } })
      expect(actor.time).to be_a(Integer).and be_positive

      allow(actor).to receive(:settings).and_return({ discovery: { interval_seconds: 0 } })
      expect(actor.time).to be_a(Integer).and be_positive
    end
  end

  # ── Claim + activate ────────────────────────────────────────────────────────

  describe 'claim and activation' do
    it 'claims, probes, and activates a configured instance on the first tick' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
      expect(registry.snapshot.offerings_for(instance_key: key).size).to eq(1)
    end

    # Identity = the operator's config NAME (the key the router resolves
    # instances.<name> settings by); the derived endpoint id is the secondary
    # physical field (dedup/diagnostics only).
    it 'publishes the config name as instance_id with the derived endpoint id as the physical id' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual

      record = registry.snapshot.instance(instance_key: key_for(:eastus, instance_cfg: eastus_cfg))
      expect(record.instance_key.instance_id).to eq('eastus')
      fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint('ak-spec-eastus')
      expect(record.instance_key.physical_id).to eq("eastus.services.ai.azure.com:443/ak:#{fingerprint}")
    end

    it 'skips credential-less and disabled instances (never claims a fallback identity)' do
      naked = { azure_foundry_endpoint: 'https://naked.services.ai.azure.com', tier: :cloud }
      disabled = { azure_foundry_endpoint: 'https://disabled.services.ai.azure.com',
                   azure_foundry_api_key: 'ak-x', enabled: false }
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ naked: naked, disabled: disabled })

      actor.manual

      expect(registry.snapshot.each_instance.to_a).to be_empty
    end

    it 'stays initializing when the catalog fetch fails (never activates an empty catalog)' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive_messages(
        check_health: readiness[:ready], fetch_catalog_entries: nil
      )

      actor.manual

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # ── D4: recovery after initial readiness failure ────────────────────────────

  describe 'initial readiness failure recovery' do
    it 'activates the instance on a later tick once readiness passes' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:unready], readiness[:ready])

      actor.manual # initial discovery: claim + readiness FAILED

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      actor.manual # tick: re-probe → readiness passes → re-activate

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end

    it 'stays initializing while readiness keeps failing' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:unready])

      actor.manual
      actor.manual
      actor.manual

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # ── D4/tick reconcile: late-configured and removed instances ────────────────

  describe 'tick reconciliation' do
    it 'adds instances that appear in config after boot and removes ones that disappear' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg }, { westus: westus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for(:eastus, instance_cfg: eastus_cfg))).not_to be_nil
      expect(registry.snapshot.instance(instance_key: key_for(:westus, instance_cfg: westus_cfg))).to be_nil

      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for(:eastus, instance_cfg: eastus_cfg)))
        .to be_nil, 'removed instance must be retired'
      expect(registry.snapshot.instance(instance_key: key_for(:westus, instance_cfg: westus_cfg)))
        .not_to be_nil, 'late instance must be claimed'
    end
  end

  # ── D16: discovery error boundary — programming errors must not become nil ──

  describe 'discovery error boundary (D16)' do
    it 'propagates programming errors instead of publishing zero offerings' do
      allow(actor).to receive(:fetch_catalog_entries).and_raise(NoMethodError, "undefined method 'model_id_for'")

      expect do
        actor.send(:discover_offerings_for_instance, instance_cfg: {}, instance_key: nil)
      end.to raise_error(NoMethodError)
    end
  end

  # ── Catalog-driven discovery ────────────────────────────────────────────────

  describe 'live catalog discovery' do
    it 'builds one offering per catalog entry from the live endpoint' do
      key = key_for(:eastus, instance_cfg: eastus_cfg)
      drafts = actor.send(:build_offering_drafts, entries: catalog, instance_cfg: eastus_cfg,
                                                  instance_key: key)

      expect(drafts.size).to eq(1)
      expect(drafts.first.provider_native_key).to eq('gpt-4o-deployment')
      expect(drafts.first.publication_source).to eq(:provider_catalog)
    end

    it 'sends bearer tokens on the catalog connection (not only api-key)' do
      bearer_cfg = {
        azure_foundry_endpoint: 'https://bearer.services.ai.azure.com',
        azure_foundry_bearer_token: 'bt-spec'
      }
      conn = actor.send(:build_health_connection,
                        endpoint: bearer_cfg[:azure_foundry_endpoint], instance_cfg: bearer_cfg)

      expect(conn.headers['Authorization']).to eq('Bearer bt-spec')
      expect(conn.headers['api-key']).to be_nil
    end
  end

  # ── Snapshot replace churn ──────────────────────────────────────────────────

  describe 'snapshot replace churn' do
    it 'does not bump the publication sequence when the catalog is unchanged' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual # initial activate (fresh drafts, sequence 1)
      actor.manual # tick 1 (fresh drafts again — observed_at differs, catalog does not)
      actor.manual # tick 2

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).published_sequence)
        .to eq(1), 'unchanged offerings must not bump the publication sequence'
    end

    it 'replaces the snapshot when the catalog actually changes' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])
      # First tick (claim + initial discovery) sees one model; the next tick
      # the endpoint reports an added embedding model.
      allow(actor).to receive(:fetch_catalog_entries)
        .and_return(catalog,
                    catalog + [{ 'id' => 'embed-deployment', 'model_name' => 'text-embedding-3-small' }])

      actor.manual # initial activate with one model
      actor.manual # tick: second model appears → replace

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(2)
      expect(registry.snapshot.offerings_for(instance_key: key).size).to eq(2)
    end

    it 'keeps the last complete snapshot when a refresh fetch fails' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])
      allow(actor).to receive(:fetch_catalog_entries).and_return(catalog, nil)

      actor.manual # initial activate with one model
      actor.manual # tick: fetch fails → snapshot untouched

      key = key_for(:eastus, instance_cfg: eastus_cfg)
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.offerings_for(instance_key: key).size).to eq(1)
      expect(registry.snapshot.publication_status(instance_key: key).published_sequence).to eq(1)
    end
  end

  # ── D14: settings health hash + capabilities after registry commits ────────

  describe 'settings display health (D14)' do
    it 'writes the legacy 4-key health shape plus capabilities after each registry commit' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:unready], readiness[:ready])

      actor.manual # initial failure

      health = actor.settings.dig(:instances, :eastus, :health)
      expect(health).to include(
        circuit_state: :open, denied: false, available: false, adjustment: -50
      )
      expect(health[:last_probe_outcome]).to eq(:failure)
      expect(health[:source]).to eq(:startup_readiness)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(String)
      expect(health[:observed_at]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\z/)

      actor.manual # recovery

      health = actor.settings.dig(:instances, :eastus, :health)
      expect(health).to include(
        circuit_state: :closed, denied: false, available: true, adjustment: 0
      )
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(actor.settings.dig(:instances, :eastus, :capabilities)).to include(:completion, :streaming)
    end

    it 'keys the health hash by the config name, not the derived physical id' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual

      expect(actor.settings[:instances].keys).to eq([:eastus])
      physical_id = actor.send(:derive_physical_id, instance_cfg: eastus_cfg)
      expect(actor.settings[:instances].keys).not_to include(physical_id)
      expect(actor.settings.dig(:instances, :eastus, :health)[:available]).to be(true)
    end

    it 'clears the health hash when the instance is removed from config' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg }, {})
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual
      expect(actor.settings.dig(:instances, :eastus, :health)).not_to be_nil

      actor.manual # instance gone → retired
      expect(actor.settings.dig(:instances, :eastus, :health)).to be_nil
      expect(registry.snapshot.instance(instance_key: key_for(:eastus, instance_cfg: eastus_cfg))).to be_nil
    end

    it 'clears the health hash and releases the registry on shutdown' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual
      expect(actor.settings.dig(:instances, :eastus, :health)).not_to be_nil

      actor.shutdown
      expect(actor.settings.dig(:instances, :eastus, :health)).to be_nil
      expect(actor.settings.dig(:instances, :eastus, :capabilities)).to be_nil
      expect(registry.snapshot.instance(instance_key: key_for(:eastus, instance_cfg: eastus_cfg))).to be_nil
    end
  end

  # ── D12: runtime state in a process-local store, never in settings ─────────

  describe 'per-instance runtime state (D12)' do
    it 'keeps the publisher token and probe coordinator in a Concurrent::Map, not settings' do
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: eastus_cfg })
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual

      states = actor.instance_variable_get(:@instance_states)
      expect(states).to be_a(Concurrent::Map)
      expect(states.size).to eq(1)
      state = states.values.first
      expect(state[:publisher_token]).to respond_to(:publisher_token_id)
      expect(state[:probe_coordinator]).to respond_to(:begin_probe)

      # No live objects or secrets may leak into the settings tree.
      expect(actor.settings).to have_key(:instances)
      expect(actor.settings).not_to have_key(:publisher_token)
      expect(actor.settings).not_to have_key(:probe_coordinator)
    end
  end
end
