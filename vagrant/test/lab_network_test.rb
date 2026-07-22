# vagrant/test/lab_network_test.rb
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/topology'
require_relative '../lib/lab_network'

# Unit tests for the dynamic host-only /24 allocator. `subnets:`, `registered:`
# and `claims_path:` are injected so these never shell out to VBoxManage and
# never touch the real ~/.straylight claim registry.
class LabNetworkTest < Minitest::Test
  def setup
    Topology.reset!   # base network = topology.yml's "192.168.56"
    @tmpdir = Dir.mktmpdir('labnet')
    @claims = File.join(@tmpdir, 'claims.json')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  # ["192.168.56", 56] from the topology base.
  def base
    a, b, c = Topology.network.split('.')
    ["#{a}.#{b}", c.to_i]
  end

  # for_lab with hermetic defaults; individual tests override as needed.
  def alloc(vbox_prefix, subnets: [], registered: [], now: Time.now, **kw)
    LabNetwork.for_lab(vbox_prefix, subnets: subnets, registered: registered,
                       claims_path: @claims, now: now, **kw)
  end

  def test_allocates_base_when_nothing_running
    prefix, b = base
    assert_equal "#{prefix}.#{b}", alloc('straylight-core')
  end

  def test_skips_subnet_in_use_by_another_lab
    prefix, b = base
    others = [["straylight-pqc-full-dc1", b]]
    assert_equal "#{prefix}.#{b + 1}", alloc('straylight-core', subnets: others)
  end

  def test_finds_lowest_free_gap
    prefix, b = base
    others = [["straylight-a-dc1", b], ["straylight-b-dc1", b + 2]]
    assert_equal "#{prefix}.#{b + 1}", alloc('straylight-core', subnets: others)
  end

  def test_reuses_own_running_subnet
    prefix, b = base
    # own VMs already on b+5: reuse it (stable across provision/validate) even
    # though the base octet is "free".
    mine = [["straylight-core-dc1", b + 5], ["straylight-other-dc1", b]]
    assert_equal "#{prefix}.#{b + 5}", alloc('straylight-core', subnets: mine)
  end

  def test_not_locked_to_profile
    prefix, b = base
    # Same profile, different result depending on what else is running -> the
    # subnet is NOT pinned to the profile (a claim yields when another lab's
    # running VMs actually hold the /24).
    fresh     = alloc('straylight-core')
    contended = alloc('straylight-core', subnets: [["straylight-x-dc1", b]])
    assert_equal "#{prefix}.#{b}", fresh
    assert_equal "#{prefix}.#{b + 1}", contended
  end

  def test_own_vms_exact_match_avoids_prefix_collision
    prefix, b = base
    # "straylight-pqc-full" is running on b+1. A different lab whose prefix is
    # "straylight-pqc" (a hyphen-prefix) must NOT reuse pqc-full's /24 — with
    # exact own_vms matching it allocates the free base instead.
    running = [["straylight-pqc-full-dc1", b + 1]]
    own = ["straylight-pqc-dc1", "straylight-pqc-web1"]
    assert_equal "#{prefix}.#{b}",
                 alloc("straylight-pqc", own_vms: own, subnets: running)
  end

  def test_own_vms_exact_match_reuses_own_running_subnet
    prefix, b = base
    running = [["straylight-pqc-dc1", b + 3], ["straylight-pqc-full-dc1", b]]
    own = ["straylight-pqc-dc1"]
    assert_equal "#{prefix}.#{b + 3}",
                 alloc("straylight-pqc", own_vms: own, subnets: running)
  end

  # ── Claim registry (the 2026-07-01 full/pqc-full same-window race) ────────

  def test_same_window_allocation_gets_distinct_subnets
    prefix, b = base
    # Neither lab has ANY VM registered yet (the launch window). The second
    # allocator must see the first's claim and take the next /24 — this is the
    # exact race that handed both full and pqc-full 192.168.59.
    first  = alloc('straylight-pqc-full')
    second = alloc('straylight-full')
    assert_equal "#{prefix}.#{b}", first
    assert_equal "#{prefix}.#{b + 1}", second
  end

  def test_claim_reused_across_invocations
    prefix, b = base
    2.times { assert_equal "#{prefix}.#{b}", alloc('straylight-core') }
  end

  def test_halted_lab_keeps_its_subnet
    prefix, b = base
    t0 = Time.now
    assert_equal "#{prefix}.#{b}", alloc('straylight-core', now: t0)
    # Hours later the lab is halted (registered but not running): the claim
    # outlives the grace window because the VMs are still registered.
    later = t0 + (LabNetwork::CLAIM_GRACE_SEC * 4)
    assert_equal "#{prefix}.#{b}",
                 alloc('straylight-core', registered: ['straylight-core-dc1'], now: later)
  end

  def test_stale_claim_expires_and_frees_subnet
    prefix, b = base
    t0 = Time.now
    alloc('straylight-old', now: t0)   # claims base, never registers a VM
    later = t0 + LabNetwork::CLAIM_GRACE_SEC + 60
    # A different lab allocating after the grace window gets the base octet.
    assert_equal "#{prefix}.#{b}", alloc('straylight-new', now: later)
  end

  def test_fresh_claim_survives_within_grace_window
    prefix, b = base
    t0 = Time.now
    alloc('straylight-young', now: t0)
    soon = t0 + 60
    assert_equal "#{prefix}.#{b + 1}", alloc('straylight-other', now: soon)
  end

  def test_claim_yields_to_other_labs_running_vms
    prefix, b = base
    t0 = Time.now
    assert_equal "#{prefix}.#{b}", alloc('straylight-core', now: t0)
    # Another lab's running VMs took the claimed /24 (e.g. claim sat idle);
    # running VMs win and this lab moves on rather than colliding.
    taken = [["straylight-x-dc1", b]]
    assert_equal "#{prefix}.#{b + 1}",
                 alloc('straylight-core', subnets: taken, now: t0 + 60)
  end

  def test_running_vms_override_stored_claim
    prefix, b = base
    t0 = Time.now
    assert_equal "#{prefix}.#{b}", alloc('straylight-core', now: t0)
    # The lab's own RUNNING VMs are authoritative even if the claim says base.
    mine = [["straylight-core-dc1", b + 5]]
    assert_equal "#{prefix}.#{b + 5}",
                 alloc('straylight-core', subnets: mine,
                       registered: ['straylight-core-dc1'], now: t0 + 60)
  end
end
