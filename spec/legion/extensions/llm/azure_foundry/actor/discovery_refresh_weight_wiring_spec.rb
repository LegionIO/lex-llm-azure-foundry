# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::AzureFoundry::Actor::DiscoveryRefresh do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:actor) { described_class.new }
  let(:instance_id) { 'eastus' }
  let(:deployment_name) { 'gpt-4o-deployment' }
  let(:model_id) { 'gpt-4o' }
  let(:instance_cfg) do
    {
      azure_foundry_endpoint: 'https://eastus.services.ai.azure.com',
      tier: :cloud,
      azure_foundry_api_key: 'ak-spec-eastus',
      azure_foundry_surface: :model_inference,
      azure_foundry_deployments: [
        { deployment: deployment_name, model: model_id, usage_type: :inference }
      ]
    }
  end
  let(:ready) do
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true, reason: 'ready', metadata: { status: 200 }
    )
  end
  let(:unready) do
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: false, reason: 'not ready', metadata: { status: 503 }
    )
  end
  let(:settings_tree) { identity_settings }

  before do
    registry.reset!
    allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
      .and_return({ eastus: instance_cfg })
    allow(actor).to receive(:check_health).and_return(ready)
    allow(Legion::Settings).to receive(:dig) { |*keys| settings_tree.dig(*keys) }
  end

  def identity_settings
    {
      extensions: { llm: { azure_foundry: {} } },
      llm: { routing: { tier_weights: {} } }
    }
  end

  def instance_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :azure_foundry,
      instance_id: instance_id,
      physical_id: actor.send(:derive_physical_id, instance_cfg: instance_cfg)
    )
  end

  def offering_id
    Legion::Extensions::Llm::Inventory::Identity.offering_id(
      instance_key: instance_key, provider_native_key: deployment_name
    )
  end

  def set_weights(tier: 100, provider: 100, instance: 100, model: nil, offering: nil)
    provider_config = { weight: provider, instances: { instance_id => { weight: instance } } }
    provider_config[:models] = { model_id => { weight: model } } unless model.nil?
    provider_config[:offerings] = { offering_id => { weight: offering } } unless offering.nil?
    settings_tree[:extensions][:llm][:azure_foundry] = provider_config
    settings_tree[:llm][:routing][:tier_weights] = { cloud: tier }
  end

  def state
    actor.instance_variable_get(:@instance_states).fetch(instance_id)
  end

  def published_offering
    registry.snapshot.offerings_for(instance_key: instance_key).fetch(0)
  end

  def publication_sequence
    registry.snapshot.publication_status(instance_key: instance_key).published_sequence
  end

  describe 'write-time weights on the existing discovery cadence' do
    it 'uses deployment_name, not model_id, for offering-scoped weight identity' do
      set_weights(tier: 110, provider: 120, instance: 130, model: 140, offering: 150)

      draft = actor.send(:discover_offerings_for_instance, instance_cfg: instance_cfg, instance_key: instance_key).first

      expect(deployment_name).not_to eq(model_id)
      expect(draft.provider_native_key).to eq(deployment_name)
      expect(draft.weight_inputs).to eq(tier: 110, provider: 120, instance: 130, model_or_offering: 150)
      expect(draft.base_weight).to eq(257_400_000)
      expect(draft.weight_inputs).to be_frozen
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      set_weights(instance: 100)
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      set_weights(instance: 130)
      actor.manual

      expect(publisher).to have_received(:replace_instance_snapshot).once
      expect(publication_sequence).to eq(2)
      expect(published_offering.weight_inputs[:instance]).to eq(130)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(130)
    end

    it 'publishes one replacement when publication source changes without identity, tier, or weight drift' do
      actor.manual
      publisher = actor.send(:publisher)
      original = state[:offerings].fetch(0)
      changed = Legion::Extensions::Llm::Inventory::OfferingDraft.new(
        **original.to_h, publication_source: :provider_control_plane
      )
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(actor).to receive(:discover_offerings_for_instance).and_return([changed])

      actor.manual

      expect(publisher).to have_received(:replace_instance_snapshot).once
      expect(publication_sequence).to eq(2)
      expect(state[:sequence]).to eq(2)
      expect(published_offering.publication_source).to eq(:provider_control_plane)
    end

    it 'does not replace a freshly observed equivalent two-offering catalog whose order changes' do
      deployments = [
        { deployment: 'gpt-4o-deployment', model: 'gpt-4o', usage_type: :inference },
        { deployment: 'gpt-4o-mini-deployment', model: 'gpt-4o-mini', usage_type: :inference }
      ]
      catalog_config = instance_cfg.merge(azure_foundry_deployments: deployments)
      original = actor.send(
        :discover_offerings_for_instance, instance_cfg: catalog_config, instance_key: instance_key
      )
      reordered = actor.send(
        :discover_offerings_for_instance,
        instance_cfg: catalog_config.merge(azure_foundry_deployments: deployments.reverse),
        instance_key: instance_key
      )
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({ eastus: catalog_config })
      allow(actor).to receive(:discover_offerings_for_instance).and_return(original, reordered)
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      actor.manual
      actor.manual

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publication_sequence).to eq(1)
      expect(state[:sequence]).to eq(1)
      expect(registry.snapshot.offerings_for(instance_key: instance_key).size).to eq(2)
    end

    it 'keeps a duplicate-count change significant through Registry validation' do
      actor.manual
      publisher = actor.send(:publisher)
      original = state[:offerings].fetch(0)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(actor).to receive(:discover_offerings_for_instance).and_return([original, original])

      expect do
        actor.send(:refresh_activated_instance, instance_id: instance_id, state: state)
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /duplicate provider_native_key/)

      expect(publisher).to have_received(:replace_instance_snapshot).once
      expect(publication_sequence).to eq(1)
      expect(state[:sequence]).to eq(1)
      expect(state[:offerings]).to eq([original])
    end

    it 'does not publish when settings change without changing the weight pair' do
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      settings_tree[:extensions][:llm][:azure_foundry][:unrelated] = 'changed'

      actor.manual

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publication_sequence).to eq(1)
    end

    it 'stores zero as a disabling component and raises on false' do
      set_weights(instance: 0)
      draft = actor.send(:discover_offerings_for_instance, instance_cfg: instance_cfg, instance_key: instance_key).first
      expect(draft.weight_inputs[:instance]).to eq(0)
      expect(draft.base_weight).to eq(0)

      set_weights(instance: false)
      expect do
        actor.send(:discover_offerings_for_instance, instance_cfg: instance_cfg, instance_key: instance_key)
      end.to raise_error(ArgumentError, /weight component/)
    end

    it 'leaves no claimed scope for malformed weights and cleanly retries after correction' do
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:claim_instance).and_call_original
      set_weights(instance: false)

      actor.manual

      snapshot = registry.snapshot
      expect(publisher).not_to have_received(:claim_instance)
      expect(snapshot.each_publication_status.to_a).to be_empty
      expect(snapshot.each_instance.to_a).to be_empty
      expect(snapshot.each_offering.to_a).to be_empty
      expect(actor.instance_variable_get(:@instance_states)).to be_empty

      set_weights(instance: 115)
      actor.manual
      actor.manual

      expect(publisher).to have_received(:claim_instance).once
      expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(:complete)
      expect(registry.snapshot.each_instance.to_a.size).to eq(1)
      expect(registry.snapshot.offerings_for(instance_key: instance_key).size).to eq(1)
      expect(state[:published]).to be(true)
    end

    it 'logs each dormant period once, clears on publication, and logs after re-disappearance' do
      logger = instance_double(Logger, info: nil, warn: nil, debug: nil)
      allow(actor).to receive(:log).and_return(logger)
      set_weights(provider: 120)
      allow(Legion::Extensions::Llm::AzureFoundry).to receive(:discover_instances)
        .and_return({}, {}, { eastus: instance_cfg }, {})

      actor.manual
      actor.manual
      actor.manual
      actor.manual

      message = '[llm][azure_foundry] action=dormant_weight ' \
                'weight_key=[:azure_foundry, :provider] no_lane_published=true'
      expect(logger).to have_received(:info).with(message).twice
    end

    it 'keeps sequence stable across ten unchanged ordinary passes' do
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      10.times { actor.manual }

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publication_sequence).to eq(1)
      expect(state[:sequence]).to eq(1)
    end

    it 'does not couple tick or shutdown to Settings lifecycle methods' do
      allow(Legion::Settings).to receive(:on_reload)
      allow(Legion::Settings).to receive(:reload!)
      allow(Legion::Settings).to receive(:reset!)

      actor.manual
      actor.shutdown

      expect(Legion::Settings).not_to have_received(:on_reload)
      expect(Legion::Settings).not_to have_received(:reload!)
      expect(Legion::Settings).not_to have_received(:reset!)
      expect(actor.instance_variable_get(:@instance_states)).to be_empty
      expect(actor.instance_variable_get(:@dormant_weight_tracker)).to be_a(
        Legion::Extensions::Llm::Inventory::DormantWeightTracker
      )
    end

    it 'serializes interleaved unchanged-weight passes to one replacement and one cache value' do
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      set_weights(instance: 135)
      gate = Queue.new
      release = Queue.new
      allow(actor).to receive(:discover_offerings_for_instance).and_wrap_original do |original, **kwargs|
        discovered = original.call(**kwargs)
        gate << true
        release.pop
        discovered
      end

      threads = Array.new(2) do
        Thread.new { actor.send(:refresh_activated_instance, instance_id: instance_id, state: state) }
      end
      2.times { gate.pop }
      2.times { release << true }
      threads.each(&:join)

      expect(publisher).to have_received(:replace_instance_snapshot).once
      expect(publication_sequence).to eq(2)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(135)
      expect(published_offering.weight_inputs[:instance]).to eq(135)
    end

    it 'leaves the published cache unchanged on replace failure and retries next pass' do
      actor.manual
      publisher = actor.send(:publisher)
      set_weights(instance: 145)
      before_sequence = state[:sequence]
      before_offerings = state[:offerings]
      allow(publisher).to receive(:replace_instance_snapshot).and_raise(RuntimeError, 'publish failed')

      expect do
        actor.send(:refresh_activated_instance, instance_id: instance_id, state: state)
      end.to raise_error(RuntimeError, 'publish failed')
      expect(state[:sequence]).to eq(before_sequence)
      expect(state[:offerings]).to equal(before_offerings)

      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      actor.send(:refresh_activated_instance, instance_id: instance_id, state: state)
      expect(state[:sequence]).to eq(before_sequence + 1)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(145)
    end

    it 'rebuilds from current Settings between draft construction and initial activation' do
      set_weights(instance: 105)
      allow(actor).to receive(:check_health) do
        set_weights(instance: 155)
        ready
      end

      actor.manual

      expect(published_offering.weight_inputs[:instance]).to eq(155)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(155)
      expect(state[:published]).to be(true)
    end

    it 'updates an unpublished cache without replace or activate and keeps it dormant' do
      allow(actor).to receive(:check_health).and_return(unready)
      actor.manual
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      set_weights(instance: 165)

      actor.manual

      expect(state[:published]).to be(false)
      expect(state[:offerings].first.weight_inputs[:instance]).to eq(165)
      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publisher).not_to have_received(:activate_instance_snapshot)
    end

    it 'does not resurrect a tracked state removed while readiness is outstanding' do
      allow(actor).to receive(:check_health).and_return(unready)
      actor.manual
      tracked = state
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      allow(actor).to receive(:write_instance_health).and_call_original
      actor.send(:remove_instance_state, instance_id)

      result = actor.send(
        :activate_after_readiness?, instance_id: instance_id, state: tracked, probe_token: 'probe-after-removal'
      )

      expect(result).to be(false)
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(actor).not_to have_received(:write_instance_health)
    end

    it 'leaves unpublished state unchanged on activation failure and permits retry' do
      allow(actor).to receive(:check_health).and_return(unready)
      actor.manual
      tracked = state
      publisher = actor.send(:publisher)
      before_sequence = tracked[:sequence]
      before_offerings = tracked[:offerings]
      allow(publisher).to receive(:activate_instance_snapshot).and_raise(RuntimeError, 'activate failed')
      allow(actor).to receive(:check_health).and_return(ready)

      actor.manual
      expect(tracked[:sequence]).to eq(before_sequence)
      expect(tracked[:offerings]).to equal(before_offerings)
      expect(tracked[:published]).to be(false)

      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      actor.manual
      expect(tracked[:published]).to be(true)
      expect(tracked[:sequence]).to eq(before_sequence + 1)
    end
  end
end
