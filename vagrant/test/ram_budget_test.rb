# Run with: ruby -I vagrant/lib vagrant/test/ram_budget_test.rb
require 'minitest/autorun'
require 'ram_budget'
require 'topology'

class RamBudgetTest < Minitest::Test
  VAGRANTFILE = File.expand_path('../Vagrantfile', __dir__)

  # ── VM→class map drift guards ────────────────────────────────────

  # The Vagrantfile define blocks are where each VM's resource class is
  # actually applied (vb.memory = vm_memory("dc1", VM_DEFAULTS[:dc][:memory])).
  # RamBudget::VM_CLASS restates that mapping so the preflight can price a
  # profile without loading Vagrant; this test kills drift between the two.
  def test_vm_class_matches_vagrantfile
    parsed = File.read(VAGRANTFILE)
                 .scan(/vm_memory\("([\w-]+)",\s*VM_DEFAULTS\[:(\w+)\]/)
                 .to_h { |vm, klass| [vm, klass.to_sym] }
    refute_empty parsed, 'failed to parse any vm_memory() calls from Vagrantfile'
    assert_equal parsed, RamBudget::VM_CLASS
  end

  def test_vm_class_covers_topology
    assert_equal Topology.names.sort, RamBudget::VM_CLASS.keys.sort
  end

  # ── Effective per-VM memory ──────────────────────────────────────

  def test_default_memory_lookup
    assert_equal 2048, RamBudget.vm_memory_mb('web1', {})
    assert_equal 8192, RamBudget.vm_memory_mb('manage1', {})
    assert_equal 1024, RamBudget.vm_memory_mb('acme1', {})
  end

  def test_profile_resource_override_wins
    resources = { 'web1' => { 'memory' => 4096 } }
    assert_equal 4096, RamBudget.vm_memory_mb('web1', resources)
  end

  def test_unknown_vm_raises
    assert_raises(RamBudget::Error) { RamBudget.vm_memory_mb('nonesuch9', {}) }
  end

  def test_total_mb_sums_components
    # dc1 (4096) + web1 (2048) + acme1 (1024)
    assert_equal 7168, RamBudget.total_mb(%w[dc1 web1 acme1], {})
  end

  # ── Host reserve policy ──────────────────────────────────────────

  def test_default_reserve_is_ten_percent_with_8gib_floor
    assert_equal 12_858, RamBudget.default_reserve_mb(128_585) # 10% of 125.6 GiB
    assert_equal 8_192,  RamBudget.default_reserve_mb(32_768)  # floor beats 3.2 GiB
  end

  # ── assess() — the budget verdict ────────────────────────────────

  def small_profile
    %w[dc1 web1 manage1] # 4096 + 2048 + 8192 = 14336 MB
  end

  def test_assess_fits_on_idle_host
    r = RamBudget.assess(components: small_profile, resources: {},
                         vbox_prefix: 'straylight-core',
                         mem_total_mb: 128_585, running: [])
    assert r[:ok]
    assert_equal 14_336, r[:incoming_mb]
    assert_equal 0, r[:committed_mb]
    assert_equal 0, r[:overshoot_mb]
  end

  # Replay of the 2026-07-02 incident: pqc-full (13 VMs) already running,
  # full (18 VMs) about to launch on a 125.6 GiB host. Must refuse.
  def test_assess_refuses_second_big_lab
    running = RamBudget::VM_CLASS.keys.first(13).map do |vm|
      { name: "straylight-pqc-full-#{vm}", memory_mb: 4096 }
    end
    full = %w[dc1 dc2 ca1 rootca issueca web1 sqlhost1 client1 manage1
              tomcat1 wsus1 ejbca1 hydra1 observe1 stepca1 acme1 scanner1 apps1]
    r = RamBudget.assess(components: full, resources: {},
                         vbox_prefix: 'straylight-full',
                         mem_total_mb: 128_585, running: running)
    refute r[:ok]
    assert_equal 13 * 4096, r[:committed_mb]
    assert_operator r[:overshoot_mb], :>, 0
    assert_equal r[:committed_mb] + r[:incoming_mb] - r[:budget_mb], r[:overshoot_mb]
  end

  # Reprovision case: this lab's own VMs are already running. They are
  # committed, not incoming — a plain re-run must not double-count them.
  def test_assess_excludes_own_running_vms_from_incoming
    running = small_profile.map do |vm|
      { name: "straylight-core-#{vm}", memory_mb: RamBudget.vm_memory_mb(vm, {}) }
    end
    r = RamBudget.assess(components: small_profile, resources: {},
                         vbox_prefix: 'straylight-core',
                         mem_total_mb: 128_585, running: running)
    assert r[:ok]
    assert_equal 0, r[:incoming_mb]
    assert_equal 14_336, r[:committed_mb]
    assert_equal small_profile.sort, r[:already_running].sort
  end

  def test_assess_counts_foreign_running_vms_as_committed
    running = [{ name: 'some-other-box', memory_mb: 10_000 }]
    r = RamBudget.assess(components: small_profile, resources: {},
                         vbox_prefix: 'straylight-core',
                         mem_total_mb: 128_585, running: running)
    assert_equal 10_000, r[:committed_mb]
    assert_equal 14_336, r[:incoming_mb]
  end

  def test_assess_honors_reserve_override
    r = RamBudget.assess(components: small_profile, resources: {},
                         vbox_prefix: 'straylight-core',
                         mem_total_mb: 16_384, running: [],
                         reserve_mb: 1_024)
    assert r[:ok] # 14336 <= 16384 - 1024
    r2 = RamBudget.assess(components: small_profile, resources: {},
                          vbox_prefix: 'straylight-core',
                          mem_total_mb: 16_384, running: [],
                          reserve_mb: 4_096)
    refute r2[:ok] # 14336 > 16384 - 4096
  end
end
