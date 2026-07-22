# vagrant/lib/topology.rb
#
# Loads vagrant/topology.yml — the authoritative VM table — and exposes
# derivations consumed by config.rb (IP_ADDRESSES), lib/lab_profile.rb
# (VALID_COMPONENTS), and the Vagrantfile (INVENTORY_HOSTS, define blocks,
# build order). Replaces the hand-synced VM representations that
# previously had to be kept in agreement across these consumers.
#
# Loaded automatically on require (bottom of this file).
require 'yaml'

module Topology
  PATH = File.expand_path('../topology.yml', __dir__)

  class Error < StandardError; end

  def self.data
    @data ||= load!
  end

  def self.load!(path = PATH)
    raise Error, "topology file not found: #{path}" unless File.file?(path)
    @data = YAML.load_file(path)
    raise Error, "topology.yml missing top-level 'vms'" unless @data.is_a?(Hash) && @data['vms']
    @data
  end

  def self.reset!  # test hook
    @data = nil
    @network = nil
  end

  # Process-global network prefix ("a.b.c"). Defaults to topology.yml's base
  # `network` but config.rb overrides it per-run from LAB_NETWORK (the /24
  # allocated by lib/lab_network.rb) so ip()/ip_addresses() — and thus
  # IP_ADDRESSES, INVENTORY_HOSTS, render_inventory's lab_static_hosts — follow.
  def self.network
    @network || data.fetch('network')
  end

  def self.network=(prefix)
    @network = prefix
  end

  def self.vms
    data.fetch('vms')
  end

  def self.names
    vms.keys
  end

  # Full IP for a VM name.
  def self.ip(name)
    "#{network}.#{vms.fetch(name).fetch('octet')}"
  end

  # Symbol-keyed { name => "ip" } — drop-in for the old IP_ADDRESSES hash.
  # Keys use to_sym so hyphenated names become :"rootca-pqc".
  def self.ip_addresses
    vms.keys.each_with_object({}) { |n, h| h[n.to_sym] = ip(n) }
  end

  def self.os(name)
    vms.fetch(name).fetch('os')
  end

  def self.windows
    names.select { |n| os(n) == 'windows' }
  end

  def self.linux
    names.select { |n| os(n) == 'linux' }
  end

  def self.groups(name)
    vms.fetch(name).fetch('groups', [])
  end

  def self.depends_on(name)
    vms.fetch(name).fetch('depends_on', [])
  end

  # Topological build order for the given component subset. Raises on cycle.
  def self.build_order(components)
    visited = {}
    order = []
    visit = lambda do |n, stack|
      return if visited[n] == :done
      raise Error, "dependency cycle at #{n} (#{stack.join(' -> ')})" if visited[n] == :active
      visited[n] = :active
      depends_on(n).each { |d| visit.call(d, stack + [n]) if components.include?(d) }
      visited[n] = :done
      order << n
    end
    components.each { |n| visit.call(n, []) }
    order
  end
end

Topology.load!
