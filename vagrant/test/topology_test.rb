# vagrant/test/topology_test.rb
require 'minitest/autorun'
require 'yaml'
require_relative '../lib/topology'
require_relative '../lib/lab_profile'

class TopologyConsistencyTest < Minitest::Test
  PROFILES_DIR = File.expand_path('../profiles', __dir__)

  def test_every_vm_has_required_fields
    Topology.vms.each do |name, v|
      assert v['octet'], "#{name}: missing octet"
      assert v['os'], "#{name}: missing os"
      assert_includes %w[windows linux], v['os'], "#{name}: bad os"
      assert v['box'] || v['os'] == 'linux', "#{name}: windows VM needs a box"
      assert v['groups'], "#{name}: missing groups"
      assert v.key?('depends_on'), "#{name}: missing depends_on (use [] if none)"
    end
  end

  def test_octets_unique
    octets = Topology.vms.values.map { |v| v['octet'] }
    assert_equal octets.length, octets.uniq.length, "duplicate octets"
  end

  def test_depends_on_targets_exist
    Topology.vms.each do |name, _|
      Topology.depends_on(name).each do |dep|
        assert Topology.vms.key?(dep), "#{name} depends_on unknown #{dep}"
      end
    end
  end

  def test_requires_ready_capabilities_are_provided
    provided = Topology.vms.values.flat_map { |v| v['provides'] || [] }.uniq
    Topology.vms.each do |name, v|
      (v['requires_ready'] || []).each do |cap|
        assert_includes provided, cap, "#{name} requires '#{cap}' which no VM provides"
      end
    end
  end

  def test_dependency_graph_is_acyclic
    Topology.build_order(Topology.names)  # raises Topology::Error on cycle
  end

  def test_every_profile_component_exists_in_topology
    Dir.glob(File.join(PROFILES_DIR, '*.yml')).each do |p|
      comps = YAML.load_file(p).fetch('components', [])
      comps.each do |c|
        assert Topology.vms.key?(c),
               "profile #{File.basename(p)} references '#{c}' not in topology.yml"
      end
    end
  end

  def test_valid_components_matches_topology
    assert_equal Topology.names.sort, LabProfile::VALID_COMPONENTS.sort,
                 "VALID_COMPONENTS drifted from topology.yml"
  end
end
