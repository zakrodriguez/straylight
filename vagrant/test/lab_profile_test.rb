# Run with: ruby -I vagrant/lib vagrant/test/lab_profile_test.rb
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'lab_profile'

def silence_warnings
  old = $VERBOSE
  $VERBOSE = nil
  yield
ensure
  $VERBOSE = old
end

class LabProfileTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('lab-profile-test-')
    @profiles_dir = File.join(@tmpdir, 'profiles')
    FileUtils.mkdir_p(@profiles_dir)
    # Minitest loads this file once but setup runs per test; silence the
    # "already initialized constant" warning when re-pointing PROFILES_DIR.
    silence_warnings do
      LabProfile.const_set(:PROFILES_DIR, @profiles_dir)
    end
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
    %w[LAB_PROFILE LAB_COMPONENTS ADCS_TOPOLOGY].each { |k| ENV.delete(k) }
  end

  def write_profile(name, yaml_body)
    File.write(File.join(@profiles_dir, "#{name}.yml"), yaml_body)
  end

  # ── Happy paths ──────────────────────────────────────────────────

  def test_named_profile_resolves_components_and_naming
    write_profile('demo', <<~YAML)
      name: demo
      components: [dc1, ca1]
    YAML
    ENV['LAB_PROFILE'] = 'demo'
    r = LabProfile.resolve
    assert_equal 'demo', r[:name]
    assert_equal %w[dc1 ca1], r[:components]
    assert_equal '.vagrant-demo', r[:dotfile_dir]
    assert_equal 'straylight-demo', r[:vbox_prefix]
    assert_equal :lab_profile, r[:source]
  end

  def test_lab_components_overrides_to_custom_profile
    ENV['LAB_COMPONENTS'] = 'dc1, ca1'
    r = LabProfile.resolve
    assert_equal 'custom', r[:name]
    assert_equal %w[dc1 ca1], r[:components]
    assert_equal :lab_components, r[:source]
  end

  def test_default_is_core
    write_profile('core', "name: core\ncomponents: [dc1]\n")
    r = LabProfile.resolve
    assert_equal 'core', r[:name]
    assert_equal :default, r[:source]
  end

  def test_resource_override_and_default_helpers
    write_profile('sized', <<~YAML)
      name: sized
      components: [dc1]
      resources:
        dc1:
          memory: 4096
    YAML
    ENV['LAB_PROFILE'] = 'sized'
    r = LabProfile.resolve
    assert_equal 4096, LabProfile.mem(r[:resources], 'dc1', 2048)
    assert_equal 2048, LabProfile.mem(r[:resources], 'ca1', 2048) # falls back
    assert_equal 2,    LabProfile.cpus(r[:resources], 'dc1', 2)    # no override
  end

  # ── Validation / error paths ─────────────────────────────────────

  def test_unknown_component_raises_with_valid_list
    write_profile('bad', "name: bad\ncomponents: [dc1, notavm]\n")
    ENV['LAB_PROFILE'] = 'bad'
    err = assert_raises(RuntimeError) { LabProfile.resolve }
    assert_match(/Unknown component/, err.message)
    assert_match(/notavm/, err.message)
  end

  def test_empty_components_raises
    write_profile('empty', "name: empty\ncomponents: []\n")
    ENV['LAB_PROFILE'] = 'empty'
    err = assert_raises(RuntimeError) { LabProfile.resolve }
    assert_match(/at least one VM/, err.message)
  end

  def test_resource_override_for_absent_vm_raises
    write_profile('stray', <<~YAML)
      name: stray
      components: [dc1]
      resources:
        ca1:
          memory: 4096
    YAML
    ENV['LAB_PROFILE'] = 'stray'
    err = assert_raises(RuntimeError) { LabProfile.resolve }
    assert_match(/not in components/, err.message)
    assert_match(/ca1/, err.message)
  end

  def test_missing_profile_raises_with_available_list
    write_profile('exists', "name: exists\ncomponents: [dc1]\n")
    ENV['LAB_PROFILE'] = 'nope'
    err = assert_raises(RuntimeError) { LabProfile.resolve }
    assert_match(/Profile not found/, err.message)
    assert_match(/exists/, err.message)
  end

  def test_invalid_profile_name_rejected
    ENV['LAB_PROFILE'] = '../etc/passwd'
    assert_raises(ArgumentError) { LabProfile.resolve }
  end

  def test_removed_adcs_topology_hard_errors_with_hint
    ENV['ADCS_TOPOLOGY'] = 'two-tier'
    err = assert_raises(RuntimeError) { LabProfile.resolve }
    assert_match(/ADCS_TOPOLOGY env var was removed/, err.message)
    assert_match(/LAB_PROFILE=ad-cs-two-tier/, err.message)
  end

  # ── .env loading regression (lib/lab_env.rb) ──────────

  def write_dotenv(body)
    path = File.join(@tmpdir, '.env')
    File.write(path, body)
    path
  end

  def reset_lab_env
    LabEnv.instance_variable_set(:@loaded_keys, nil)
  end

  def test_dotenv_profile_reaches_resolver
    write_profile('wizard', "name: wizard\ncomponents: [dc1]\n")
    reset_lab_env
    LabEnv.load!(write_dotenv("# wizard output\nLAB_PROFILE=wizard\n"))
    r = LabProfile.resolve
    assert_equal 'wizard', r[:name]
    assert_equal :dotenv, r[:source]
  ensure
    reset_lab_env
  end

  def test_real_env_beats_dotenv
    write_profile('inline', "name: inline\ncomponents: [dc1]\n")
    ENV['LAB_PROFILE'] = 'inline'
    reset_lab_env
    LabEnv.load!(write_dotenv("LAB_PROFILE=wizard\n"))
    r = LabProfile.resolve
    assert_equal 'inline', r[:name]
    assert_equal :lab_profile, r[:source]
  ensure
    reset_lab_env
  end

  def test_dotenv_parses_export_prefix_quotes_and_skips_garbage
    reset_lab_env
    LabEnv.load!(write_dotenv(<<~DOTENV))
      # comment
      export LAB_PROFILE="wizard"
      LAB_DOTENV_TEST_VAL='quoted value'
      not a valid line
      =nokey
    DOTENV
    assert_equal 'wizard', ENV['LAB_PROFILE']
    assert_equal 'quoted value', ENV['LAB_DOTENV_TEST_VAL']
    assert_equal %w[LAB_PROFILE LAB_DOTENV_TEST_VAL], LabEnv.loaded_keys
  ensure
    ENV.delete('LAB_DOTENV_TEST_VAL')
    reset_lab_env
  end

  def test_dotenv_missing_file_is_noop
    reset_lab_env
    assert_equal [], LabEnv.load!(File.join(@tmpdir, 'no-such.env'))
  end
end
