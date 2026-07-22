# -*- mode: ruby -*-
#===============================================================================
# render_inventory.rb — explicit Ansible inventory generation
#===============================================================================
# Extracted verbatim from the Vagrantfile, which previously generated the static
# inventory (static.ini), the PQC inventory (pqc.ini), and group_vars/all.yml as
# a PARSE-TIME SIDE EFFECT — so every `vagrant status`, ssh-config, or
# tab-completion parse rewrote those shared files.
#
# Generation now runs ONLY when explicitly requested: the Vagrantfile calls
# RenderInventory.run(...) when LAB_RENDER_INVENTORY=1 (set by up.sh /
# render-inventory.sh) or when the inventory doesn't yet exist. The generated
# file CONTENTS are byte-identical to the previous parse-time output — only WHEN
# generation runs changed.
#===============================================================================
require 'yaml'
require 'fileutils'
require_relative 'topology'

module RenderInventory
  # Keys owned exclusively by the checked-in static
  # ansible/group_vars/all.yml (lab-wide STATIC facts that don't vary per run).
  # These are dropped from the generated per-profile group_vars/all.yml so the
  # two files stay disjoint by responsibility and never define the same key at
  # the same precedence tier. Values resolve identically in both today; the
  # static file is the single owner going forward.
  STATIC_OWNED = %w[lab_timezone lab_timezone_linux psf_init pwsh_version].freeze

  #=============================================================================
  # Dynamic Ansible inventory for PQC playbooks (pqc.ini)
  #=============================================================================
  # Replaces the hand-maintained pqc.ini. Generated from the active profile's
  # COMPONENTS + the group mapping below.
  #
  # Each group entry is { hosts: [vm names], vars: {vm => "k=v"} (optional) }.
  # Groups are emitted only if at least one of their hosts is in COMPONENTS.
  # Per-host vars (e.g. pqc_pure_leaf_endpoints' openssl_pqc_port) are inlined.
  PQC_GROUPS = {
    'ejbca'                   => { hosts: ['ejbca1'] },
    'stepca'                  => { hosts: ['stepca1'] },
    'adcs'                    => { hosts: ['ca1', 'issueca'] },
    'iis'                     => { hosts: ['web1'] },
    # domain_controllers exists so playbooks that need to reach dc1 by name
    # (chimera root dspublish, ejbca-trust, stepca-trust) resolve correctly
    # against pqc.ini. Not every PQC playbook needs it; group is emitted only
    # when the active profile includes a DC.
    'domain_controllers'      => { hosts: ['dc1', 'dc2'] },
    'linux_pqc_targets'       => { hosts: ['ejbca1', 'stepca1', 'hydra1', 'observe1'] },
    'pqc_pure_leaf_endpoints' => {
      hosts: ['observe1', 'stepca1', 'ejbca1', 'hydra1'],
      vars: {
        'observe1' => 'openssl_pqc_port=8444',
        'stepca1'  => 'openssl_pqc_port=9444',
        'ejbca1'   => 'openssl_pqc_port=8444',
        'hydra1'   => 'openssl_pqc_port=8444',
      },
    },
    # pqc-mtls.yml: scanner1 holds the ML-DSA-65 client cert that probes
    # observe1:8445 (the mTLS-required pure-PQC listener).
    'pqc_mtls_clients'        => { hosts: ['scanner1'] },
  }

  # Extra DNS aliases for lab_static_hosts that are NOT VM identities
  # (so they don't belong in topology.yml's `vms` table) but must resolve to a
  # VM's IP for walkthroughs. acme1 publishes several per-protocol vhosts
  # (step./sh./cb./alpn.) all served by the same box — these names appear in
  # AD DNS A records (acme1.yml), the acme nginx server_name, and validate.sh's
  # ACME resolution check. Rendered into the VM's `names` list below so the
  # generated lab_static_hosts stays equivalent to the old hand-kept map.
  LAB_STATIC_HOST_ALIASES = {
    'acme1' => %w[step.acme1 sh.acme1 cb.acme1 alpn.acme1],
  }.freeze

  # Group-level vars (e.g. force ssh transport for linux groups regardless of
  # ansible.cfg's default winrm setting).
  PQC_GROUP_VARS = {
    'ejbca'                   => ["ansible_connection=ssh", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"],
    'stepca'                  => ["ansible_connection=ssh", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"],
    'linux_pqc_targets'       => ["ansible_connection=ssh", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"],
    'pqc_pure_leaf_endpoints' => ["ansible_connection=ssh", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"],
    'pqc_mtls_clients'        => ["ansible_connection=ssh", "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"],
  }

  # Write `path` atomically: tempfile-in-same-dir + rename. POSIX rename is
  # atomic, so concurrent readers always see either the old file or the
  # fully-written new file — never a truncated mid-write state. The same-dir
  # tempfile is required because rename across filesystems isn't atomic.
  def self.atomic_write(path, content)
    require 'tempfile'
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    tmp = Tempfile.new([File.basename(path) + '.', '.tmp'], dir)
    begin
      tmp.write(content)
      tmp.close
      File.rename(tmp.path, path)
    rescue
      tmp.close unless tmp.closed?
      File.unlink(tmp.path) if File.exist?(tmp.path)
      raise
    end
  end

  # Build a single inventory host line (name + space-joined k=v connection vars),
  # identical to what the static.ini loop has always produced. Factored out so
  # both static.ini and the canonical inventory.ini emit byte-identical host
  # lines from one source of truth.
  #   winrm hosts: winrm_vars_base + ansible_host
  #   ssh hosts:   ssh_vars_base + ansible_host (+ private_key when it exists)
  def self.host_line(name, cfg, winrm_vars_base:, ssh_vars_base:, vagrant_root:, dotfile_dir:)
    if cfg[:type] == :winrm
      vars = winrm_vars_base.merge({ ansible_host: cfg[:ip] })
    else
      key_path = File.join(vagrant_root, dotfile_dir, "machines", name, "virtualbox", "private_key")
      vars = ssh_vars_base.merge({ ansible_host: cfg[:ip] })
      vars[:ansible_ssh_private_key_file] = key_path if File.exist?(key_path)
    end
    "#{name} " + vars.map { |k, v| "#{k}=#{v}" }.join(" ")
  end

  # Generate static.ini, pqc.ini, inventory.ini, and group_vars/all.yml for the
  # active profile. All paths derive from profile_inv_dir; private-key paths
  # derive from vagrant_root + dotfile_dir (was File.dirname(__FILE__) in the
  # Vagrantfile).
  def self.run(profile_name:, components:, inventory_hosts:, dotfile_dir:,
               profile_inv_dir:, winrm_vars_base:, ssh_vars_base:,
               common_vars:, ejbca_vars:, stepca_vars:, hydra_vars:, vagrant_root:)
    inventory_path = File.join(profile_inv_dir, "static.ini")

    inventory_lines = ["# Generated by Vagrantfile — do not edit manually"]
    inventory_hosts.each do |name, cfg|
      inventory_lines << host_line(name, cfg,
        winrm_vars_base: winrm_vars_base, ssh_vars_base: ssh_vars_base,
        vagrant_root: vagrant_root, dotfile_dir: dotfile_dir)
    end

    atomic_write(inventory_path, inventory_lines.join("\n") + "\n")

    #===========================================================================
    # pqc.ini
    #===========================================================================
    pqc_inventory_path = File.join(profile_inv_dir, "pqc.ini")
    pqc_lines = [
      "# Generated by Vagrantfile — do not edit manually",
      "# Active profile: #{profile_name} (#{components.size} VMs)",
      "",
    ]

    PQC_GROUPS.each do |group, cfg|
      active = cfg[:hosts] & components
      next if active.empty?
      pqc_lines << "[#{group}]"
      active.each do |host|
        host_cfg = inventory_hosts[host]
        next if host_cfg.nil?  # defensive — should never happen given the intersection above
        parts = ["#{host}", "ansible_host=#{host_cfg[:ip]}"]
        if host_cfg[:type] == :ssh
          key_path = File.join(vagrant_root, dotfile_dir, "machines", host, "virtualbox", "private_key")
          # ansible_connection=ssh + ansible_port=22 inlined at host level so they
          # win over any inventory-adjacent group_vars/all.yml that defaults to
          # winrm/5985 (needed because group_vars/all.yml is visible to
          # standalone ansible-playbook via inventory/group_vars symlink). Mirrors
          # the winrm-host branch below which also inlines connection + port.
          parts << "ansible_connection=ssh"
          parts << "ansible_port=22"
          parts << "ansible_user=vagrant"
          parts << "ansible_ssh_private_key_file=#{key_path}"
        else  # winrm
          parts << "ansible_user=vagrant"
          parts << "ansible_password=vagrant"
          parts << "ansible_connection=winrm"
          parts << "ansible_winrm_transport=basic"
          parts << "ansible_port=5985"
        end
        if cfg[:vars] && cfg[:vars][host]
          parts << cfg[:vars][host]
        end
        pqc_lines << parts.join(" ")
      end
      pqc_lines << ""
      if PQC_GROUP_VARS[group]
        pqc_lines << "[#{group}:vars]"
        PQC_GROUP_VARS[group].each { |v| pqc_lines << v }
        pqc_lines << ""
      end
    end

    atomic_write(pqc_inventory_path, pqc_lines.join("\n"))

    #===========================================================================
    # inventory.ini — the CANONICAL grouped inventory
    #===========================================================================
    # A single grouped inventory derived from the topology source: the ungrouped
    # top section lists every active host with its full connection vars (same
    # host_line as static.ini), then one [group] section per topology group that
    # has active members (Topology.groups, intersected with the active host set),
    # in sorted order. Groups carrying group-level vars (PQC_GROUP_VARS — ssh
    # transport forcing) also emit a [group:vars] section. static.ini and pqc.ini
    # are unchanged; all three derive from one topology model so there's no
    # hand-sync drift.
    inventory_ini_path = File.join(profile_inv_dir, "inventory.ini")
    inv_lines = [
      "# Generated from topology.yml — do not edit manually",
      "# Active profile: #{profile_name}",
      "",
    ]

    # Ungrouped top section (implicit `all`): full connection vars per host.
    inventory_hosts.each do |name, cfg|
      inv_lines << host_line(name, cfg,
        winrm_vars_base: winrm_vars_base, ssh_vars_base: ssh_vars_base,
        vagrant_root: vagrant_root, dotfile_dir: dotfile_dir)
    end
    inv_lines << ""

    # Topology-driven groups: collect group => [active members], intersecting
    # each group's topology membership with the active host set.
    active_names = inventory_hosts.keys
    group_members = Hash.new { |h, k| h[k] = [] }
    active_names.each do |name|
      Topology.groups(name).each { |g| group_members[g] << name }
    end

    group_members.keys.sort.each do |group|
      members = group_members[group]
      next if members.empty?
      inv_lines << "[#{group}]"
      members.each { |host| inv_lines << host }
      inv_lines << ""
      if PQC_GROUP_VARS[group]
        inv_lines << "[#{group}:vars]"
        PQC_GROUP_VARS[group].each { |v| inv_lines << v }
        inv_lines << ""
      end
    end

    atomic_write(inventory_ini_path, inv_lines.join("\n"))

    #===========================================================================
    # inventory/group_vars/all.yml so standalone ansible-playbook invocations
    # (pqc-remediate.sh, pqc-migrate.yml, manual debugging) see the same lab-wide
    # extra_vars that the vagrant ansible provisioner passes via extra_vars when
    # it runs site-style playbooks. Without this file, dc1's chimera-trust play
    # fails with "ejbca_ip undefined" / "lab_netbios undefined" / "psf_init
    # undefined" when invoked outside of vagrant.
    #
    # ansible auto-discovers inventory/group_vars/all.yml because ansible looks
    # for group_vars/ adjacent to the inventory file (any inventory under
    # inventory/ benefits). Filename `all.yml` makes the vars apply to every host
    # in the `all` implicit group. Inventory host-level vars in pqc.ini
    # (ansible_connection, ansible_port, ssh_private_key_file) still have higher
    # precedence than these group_vars/all.yml entries — see the host-level
    # connection inlining above.
    #===========================================================================
    lab_vars_path = File.join(profile_inv_dir, "group_vars", "all.yml")
    lab_vars = {}
    common_vars.each { |k, v| lab_vars[k.to_s] = v }
    ejbca_vars.each  { |k, v| lab_vars[k.to_s] = v }
    stepca_vars.each { |k, v| lab_vars[k.to_s] = v }
    hydra_vars.each  { |k, v| lab_vars[k.to_s] = v }
    # The two group_vars/all.yml files must be disjoint by
    # responsibility. The checked-in ansible/group_vars/all.yml owns lab-wide
    # STATIC facts (constants that don't vary per run); this generated file owns
    # only RUNTIME-DERIVED values (IPs, connection vars, per-run secrets).
    # These keys are statically owned, so we drop them here to avoid defining
    # the same key in both files at the same precedence tier (where the winner
    # would depend on the invocation path). See STATIC_OWNED below.
    lab_vars.reject! { |k, _| STATIC_OWNED.include?(k) }
    # Render lab_static_hosts from the topology source of truth instead
    # of the hand-kept map in common_linux/defaults/main.yml (now an empty
    # safety default). Shape matches the consumers — a list of
    # { "ip" => ..., "names" => [...] } — iterated by common_linux's
    # /etc/hosts blockinfile and stepca's docker-compose extra_hosts. Each VM
    # contributes its name; LAB_STATIC_HOST_ALIASES adds non-VM walkthrough
    # vhosts (e.g. step.acme1) so the rendered map is a superset of, and
    # equivalent to, the old literal.
    lab_vars['lab_static_hosts'] = Topology.names.map do |n|
      { 'ip' => Topology.ip(n), 'names' => [n] + LAB_STATIC_HOST_ALIASES.fetch(n, []) }
    end
    # Expose each VM's topology `requires_ready` capability tags
    # so the host_ready role can replace blind pauses with bounded readiness
    # probes. A playbook reads its own list via
    #   {{ topology_requires_ready[inventory_hostname] | default([]) }}.
    # Only VMs that actually declare a non-empty requires_ready are emitted.
    lab_vars['topology_requires_ready'] = Topology.vms.each_with_object({}) do |(n, v), h|
      rr = v['requires_ready']
      h[n] = rr if rr && !rr.empty?
    end
    atomic_write(lab_vars_path,
      "# Generated by Vagrantfile — do not edit manually\n" \
      "# Active profile: #{profile_name}\n" \
      "# Mirrors COMMON_VARS + EJBCA_VARS + STEPCA_VARS + HYDRA_VARS so standalone\n" \
      "# ansible-playbook invocations resolve the same lab-wide vars vagrant's\n" \
      "# ansible provisioner passes via extra_vars. Higher-precedence inventory\n" \
      "# host vars (in pqc.ini) still win for connection knobs.\n" \
      + lab_vars.to_yaml.sub(/\A---\n/, ""))
  end
end
