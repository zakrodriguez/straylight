# vagrant/lib/ram_budget.rb
#
# RAM-budget preflight for up.sh (born of the 2026-07-02 dual-lab OOM
# incident: full + pqc-full together configure ~128 GiB of guest RAM on a
# 125 GiB host — the host swap-thrashed until systemd-oomd killed a build
# terminal mid-provision).
#
# Windows guests commit essentially all of their configured RAM as they boot
# and provision, so the honest budget question is asked up front, in
# configured MB — not in MemAvailable at launch time (already-running VMs
# keep growing after you look):
#
#   committed (Σ configured RAM of running VBox VMs, any lab)
#   + incoming (Σ effective RAM of profile VMs not already running)
#   must fit in MemTotal − host reserve (10%, 8 GiB floor).
#
# Pure logic lives in assess() (tested in test/ram_budget_test.rb); cli()
# gathers real inputs from /proc/meminfo and VBoxManage for up.sh.
require_relative '../config' # VM_DEFAULTS — per-class resource defaults

module RamBudget
  class Error < StandardError; end

  # VM name → VM_DEFAULTS resource class. Restates the mapping the
  # Vagrantfile applies in its define blocks
  # (vb.memory = vm_memory("dc1", VM_DEFAULTS[:dc][:memory])) so a profile
  # can be priced without loading Vagrant. Drift is caught by
  # test/ram_budget_test.rb#test_vm_class_matches_vagrantfile.
  VM_CLASS = {
    'dc1'         => :dc,
    'dc2'         => :dc,
    'ca1'         => :ca,
    'rootca'      => :ca,
    'issueca'     => :ca,
    'rootca-pqc'  => :ca,
    'issueca-pqc' => :ca,
    'web1'        => :web,
    'sqlhost1'    => :sql,
    'client1'     => :client,
    'manage1'     => :manage,
    'tomcat1'     => :tomcat,
    'wsus1'       => :wsus,
    'ejbca1'      => :ejbca,
    'hydra1'      => :hydra,
    'observe1'    => :observe,
    'stepca1'     => :stepca,
    'acme1'       => :acme,
    'scanner1'    => :scanner,
    'apps1'       => :apps,
  }.freeze

  # Effective configured memory for one VM: profile resources override,
  # else the VM's class default. Mirrors the Vagrantfile's vm_memory().
  def self.vm_memory_mb(vm_name, resources)
    klass = VM_CLASS[vm_name] or
      raise Error, "no resource class for VM '#{vm_name}' — add it to RamBudget::VM_CLASS"
    (resources[vm_name] || {})['memory'] || VM_DEFAULTS.fetch(klass).fetch(:memory)
  end

  def self.total_mb(components, resources)
    components.sum { |vm| vm_memory_mb(vm, resources) }
  end

  # Host reserve: RAM kept back for the host OS, desktop, ansible forks and
  # VBox overhead. 10% of MemTotal with an 8 GiB floor.
  def self.default_reserve_mb(mem_total_mb)
    [mem_total_mb / 10, 8192].max
  end

  # Pure budget verdict.
  #   components:   VMs this launch will create/provision
  #   resources:    profile per-VM resource overrides ({} when none)
  #   vbox_prefix:  this lab's VBox name prefix (straylight-<profile>)
  #   mem_total_mb: host MemTotal
  #   running:      [{name:, memory_mb:}, ...] — ALL running VBox VMs
  #   reserve_mb:   override the host reserve (default: default_reserve_mb)
  #
  # Profile VMs already running are committed, not incoming — a plain
  # reprovision re-run must not price its own lab twice.
  def self.assess(components:, resources:, vbox_prefix:, mem_total_mb:,
                  running:, reserve_mb: nil)
    running_names = running.map { |vm| vm[:name] }
    already_running = components.select { |c| running_names.include?("#{vbox_prefix}-#{c}") }
    incoming_mb  = total_mb(components - already_running, resources)
    committed_mb = running.sum { |vm| vm[:memory_mb] }
    reserve_mb ||= default_reserve_mb(mem_total_mb)
    budget_mb    = mem_total_mb - reserve_mb
    need_mb      = committed_mb + incoming_mb
    {
      ok: need_mb <= budget_mb,
      incoming_mb: incoming_mb,
      committed_mb: committed_mb,
      reserve_mb: reserve_mb,
      budget_mb: budget_mb,
      overshoot_mb: [need_mb - budget_mb, 0].max,
      already_running: already_running,
      running_count: running.size,
    }
  end

  # ── Host input gathering (not under unit test — thin shims) ─────────

  def self.host_mem_total_mb
    meminfo = File.read('/proc/meminfo')
    kb = meminfo[/^MemTotal:\s+(\d+)\s*kB/, 1] or raise Error, 'MemTotal not found in /proc/meminfo'
    kb.to_i / 1024
  end

  # All running VBox VMs (any lab, any name) with configured memory, from a
  # single `VBoxManage list -l runningvms` call. Only column-0 "Name:" lines
  # are VM headers; shared-folder Name lines carry a quoted value and
  # snapshot Name lines are indented, so both fall out of the match.
  def self.running_vms
    out = `VBoxManage list -l runningvms 2>/dev/null`
    raise Error, 'VBoxManage list runningvms failed' unless $?.success?
    vms = []
    current = nil
    out.each_line do |line|
      if (m = line.match(/^Name:\s+([^'\s].*?)\s*$/))
        current = m[1]
      elsif (m = line.match(/^Memory size:\s*(\d+)MB/i)) && current
        vms << { name: current, memory_mb: m[1].to_i }
        current = nil
      end
    end
    vms
  end

  def self.format_gib(mb)
    format('%.1f GiB', mb / 1024.0)
  end

  # Entry point for up.sh. Returns the process exit code:
  #   0 fits, 2 breach, 3 the check itself failed (caller fails open).
  def self.cli(argv)
    vms = prefix = nil
    reserve_mb = mem_total_mb = nil
    args = argv.dup
    until args.empty?
      case (arg = args.shift)
      when '--vms'          then vms = args.shift.to_s.split(',').reject(&:empty?)
      when '--prefix'       then prefix = args.shift
      when '--reserve-mb'   then reserve_mb = args.shift.to_i
      when '--mem-total-mb' then mem_total_mb = args.shift.to_i # test hook
      else raise Error, "unknown argument: #{arg}"
      end
    end
    raise Error, '--vms and --prefix are required' if vms.nil? || vms.empty? || prefix.nil?

    resources = begin
      require 'lab_profile'
      LabProfile.resolve[:resources]
    rescue StandardError
      {} # pricing falls back to class defaults; never blocks the build
    end

    r = assess(components: vms, resources: resources, vbox_prefix: prefix,
               mem_total_mb: mem_total_mb || host_mem_total_mb,
               running: running_vms, reserve_mb: reserve_mb)

    incoming_n = vms.size - r[:already_running].size
    line = "  RAM preflight: incoming #{format_gib(r[:incoming_mb])} (#{incoming_n} VMs)" \
           " + running #{format_gib(r[:committed_mb])} (#{r[:running_count]} VMs)" \
           " vs budget #{format_gib(r[:budget_mb])}" \
           " (host reserve #{format_gib(r[:reserve_mb])})"
    unless r[:already_running].empty?
      line += "\n                 #{r[:already_running].size} profile VM(s) already running — counted once"
    end
    if r[:ok]
      puts "#{line} — OK"
      0
    else
      warn line
      warn "  RAM preflight: EXCEEDS budget by #{format_gib(r[:overshoot_mb])}." \
           ' Running VMs commit their full configured RAM; launching this would' \
           ' swap-thrash the host (2026-07-02 dual-lab OOM).'
      warn '  Options: stop/destroy another lab first, build profiles sequentially, or:'
      warn '    LAB_RAM_GUARD=warn bash up.sh      # proceed anyway'
      warn '    LAB_RAM_RESERVE_MB=<mb> bash up.sh # shrink the host reserve'
      2
    end
  rescue Error, StandardError => e
    warn "  RAM preflight: check failed (#{e.class}: #{e.message}) — continuing without it"
    3
  end
end
