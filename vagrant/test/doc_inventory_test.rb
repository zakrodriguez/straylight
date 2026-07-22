# vagrant/test/doc_inventory_test.rb
#
# Fleet-inventory freshness check. The fleet inventory used to be restated
# in ~5 docs with no authoritative source and no CI guard — CI only proved that
# profiles *resolve*, never that the prose inventory matched reality. This test
# makes ARCHITECTURE.md's "VM inventory" table the single human-authoritative
# inventory and fails the build if it drifts (name / IP / OS) from
# vagrant/topology.yml, the machine source of truth.
require 'minitest/autorun'
require 'yaml'

class DocInventoryFreshnessTest < Minitest::Test
  TOPO = File.expand_path('../topology.yml', __dir__)
  ARCH = File.expand_path('../../ARCHITECTURE.md', __dir__)

  def topology
    @topology ||= YAML.load_file(TOPO)
  end

  # Expected: name => {ip, os} from topology.yml.
  def expected
    net = topology['network']
    topology['vms'].each_with_object({}) do |(name, v), h|
      h[name] = { ip: "#{net}.#{v['octet']}", os: v['os'].downcase }
    end
  end

  # Parse the authoritative markdown table inside the "## VM inventory" section
  # only (so the PKI/trust tables elsewhere can't accidentally match). Rows look
  # like: | `dc1` | 192.168.56.10 | Windows | AD DS + DNS |
  def arch_rows
    rows = {}
    in_section = false
    File.foreach(ARCH) do |line|
      if line.start_with?('## ')
        in_section = line.start_with?('## VM inventory')
        next
      end
      next unless in_section
      m = line.match(/^\|\s*`([a-z0-9-]+)`\s*\|\s*(\d+\.\d+\.\d+\.\d+)\s*\|\s*(\w+)\s*\|/)
      rows[m[1]] = { ip: m[2], os: m[3].downcase } if m
    end
    rows
  end

  def test_architecture_inventory_matches_topology
    got = arch_rows
    want = expected

    refute_empty got, 'No authoritative VM table parsed from ARCHITECTURE.md "## VM inventory" section'

    missing = want.keys - got.keys
    extra   = got.keys - want.keys
    assert_empty missing, "ARCHITECTURE.md inventory is MISSING VMs that topology.yml defines: #{missing.join(', ')}"
    assert_empty extra,   "ARCHITECTURE.md inventory lists VMs NOT in topology.yml: #{extra.join(', ')}"

    want.each do |name, f|
      assert_equal f[:ip], got[name][:ip], "#{name}: IP drift (topology=#{f[:ip]} vs ARCHITECTURE=#{got[name][:ip]})"
      assert_equal f[:os], got[name][:os], "#{name}: OS drift (topology=#{f[:os]} vs ARCHITECTURE=#{got[name][:os]})"
    end
  end
end
