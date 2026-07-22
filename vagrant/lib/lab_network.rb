# vagrant/lib/lab_network.rb
#
# Dynamic host-only /24 allocation for concurrent labs.
#
# Instead of pinning each profile to a fixed subnet, every lab takes the LOWEST
# FREE third octet starting at the topology base (.56), skipping /24s already
# occupied by other labs. A profile is NOT locked to a subnet:
#   * if this profile's own VMs are already running, reuse their /24 (stable
#     across provision/validate/nuke while the lab is up);
#   * else if this profile holds a live claim (see below), reuse that;
#   * otherwise grab the next free /24 from the base upward.
#
# Occupancy = running VMs' host-only subnets (via VBoxManage) PLUS live claims
# in ~/.straylight/lab-subnets.json. The claim file exists because running VMs
# alone are a racy signal: a lab that has just launched has NO VMs registered
# for the first minutes of Phase 1, so two labs allocating in that window both
# saw the same "free" octet and collided (full + pqc-full both got .59 on
# 2026-07-01). Allocation now happens under an exclusive flock on the claim
# file, and a claim marks the /24 taken from the instant it is chosen.
#
# Claim lifecycle: a claim stays live while any VM named "<prefix>-*" is
# REGISTERED in VirtualBox (running or halted — this also fixes the old
# halted-lab limitation where a resumed lab could hop subnets), or for
# CLAIM_GRACE_SEC after it was (re)written when no VM is registered yet
# (covers the launch window). Stale claims are pruned on every allocation, so
# a nuked lab frees its /24 within the grace period at worst.
#
# With VBoxManage absent (e.g. a CI lint box) it falls back to the base prefix
# without touching the claim file, so config still parses.

require_relative 'topology'
require 'json'
require 'time'
require 'fileutils'

module LabNetwork
  module_function

  SOFT_CAP_OCTET = 63   # VBox default host-only range is 192.168.56.0/21 (.56-.63)
  CLAIMS_PATH = File.expand_path('~/.straylight/lab-subnets.json')
  CLAIM_GRACE_SEC = 30 * 60   # claim lifetime while the lab has no registered VMs

  # Active /24 prefix ("a.b.c") for the lab identified by its VBox name prefix
  # (e.g. "straylight-pqc-full"). `own_vms` is this lab's exact VBox machine
  # names; when given, the reuse-own match is EXACT rather than a prefix test
  # (a bare prefix would mis-match a profile whose name is a hyphen-prefix of
  # another, e.g. "pqc" vs "pqc-full"). `subnets`, `registered`, `claims_path`
  # and `now` are injectable for tests.
  def for_lab(vbox_prefix, own_vms: nil, subnets: nil, registered: nil,
              claims_path: CLAIMS_PATH, now: Time.now)
    a, b, base = Topology.network.split('.')
    prefix = "#{a}.#{b}"
    base = base.to_i

    # No VBoxManage and nothing injected: CI/lint fallback, no claim-file I/O.
    return "#{prefix}.#{base}" if subnets.nil? && !vboxmanage_available?

    subnets ||= running_subnets
    registered ||= registered_vms

    octet = with_claims(claims_path) do |claims|
      allocate(vbox_prefix, own_vms, subnets, registered, claims, base, now)
    end

    if octet > SOFT_CAP_OCTET
      warn "[lab_network] allocated .#{octet} is beyond the VBox default /21 " \
           "(.56-.63); widen /etc/vbox/networks.conf on the host or this `up` " \
           "will be rejected."
    end
    "#{prefix}.#{octet}"
  end

  # Read-modify-write the claim registry under an exclusive flock. Two labs
  # allocating simultaneously serialize here — the second sees the first's
  # claim and picks a different /24.
  def with_claims(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, File::RDWR | File::CREAT, 0o644) do |f|
      f.flock(File::LOCK_EX)
      claims = begin
        JSON.parse(f.read)
      rescue JSON::ParserError
        {}
      end
      result = yield claims
      f.rewind
      f.write(JSON.pretty_generate(claims))
      f.flush
      f.truncate(f.pos)
      result
    end
  end

  def allocate(vbox_prefix, own_vms, subnets, registered, claims, base, now)
    prune_stale_claims!(claims, registered, now)

    # 1. This lab's RUNNING VMs are authoritative for its subnet.
    mine = subnets.find { |name, _| own_vm?(name, vbox_prefix, own_vms) }
    octet = mine && mine[1]

    # 2. Else reuse this lab's live claim (halted lab, or mid-launch before any
    #    VM registers) — unless another lab's running VMs took that /24 while
    #    the claim sat idle.
    if !octet && (claim = claims[vbox_prefix])
      taken_by_other = subnets.any? do |name, o|
        o == claim['octet'] && !own_vm?(name, vbox_prefix, own_vms)
      end
      octet = claim['octet'] unless taken_by_other
    end

    # 3. Else lowest free octet. "Used" includes other labs' claims, not just
    #    running VMs — the fix for the same-window double allocation.
    unless octet
      used = subnets.map { |_, o| o } | claims.values.map { |c| c['octet'] }
      octet = base
      octet += 1 while used.include?(octet)
    end

    claims[vbox_prefix] = { 'octet' => octet, 'ts' => now.utc.iso8601 }
    octet
  end

  def own_vm?(name, vbox_prefix, own_vms)
    own_vms ? own_vms.include?(name) : name.start_with?("#{vbox_prefix}-")
  end

  # Drop claims whose lab has no registered VMs and whose timestamp is past the
  # grace window (never registered, or nuked).
  def prune_stale_claims!(claims, registered, now)
    claims.delete_if do |prefix, claim|
      next false if registered.any? { |vm| vm.start_with?("#{prefix}-") }
      ts = begin
        Time.parse(claim['ts'])
      rescue StandardError
        nil
      end
      ts.nil? || (now - ts) > CLAIM_GRACE_SEC
    end
  end

  # [[vm_name, third_octet], ...] for every running VBox VM on a host-only
  # adapter. Empty when VBoxManage is unavailable.
  def running_subnets
    return [] unless vboxmanage_available?
    octet_of = hostonly_adapter_octets
    running_vms.flat_map do |vm|
      hostonly_adapters(vm).filter_map do |adapter|
        o = octet_of[adapter]
        o && [vm, o]
      end
    end.uniq
  end

  def vboxmanage_available?
    system('command -v VBoxManage >/dev/null 2>&1')
  end

  def running_vms
    `VBoxManage list runningvms 2>/dev/null`.scan(/"([^"]*)"/).flatten
  end

  # Every registered VM (running or not) — a halted lab still owns its claim.
  def registered_vms
    `VBoxManage list vms 2>/dev/null`.scan(/"([^"]*)"/).flatten
  end

  def hostonly_adapters(vm)
    `VBoxManage showvminfo "#{vm}" --machinereadable 2>/dev/null`
      .scan(/^hostonlyadapter\d+="([^"]+)"/).flatten
  end

  # { "vboxnet1" => 57, ... } — third octet of each host-only adapter's host IP.
  def hostonly_adapter_octets
    octets = {}
    name = nil
    `VBoxManage list hostonlyifs 2>/dev/null`.each_line do |line|
      if line =~ /^Name:\s+(\S+)/
        name = $1
      elsif name && line =~ /^IPAddress:\s+\d+\.\d+\.(\d+)\.\d+/
        octets[name] = $1.to_i
      end
    end
    octets
  end
end
