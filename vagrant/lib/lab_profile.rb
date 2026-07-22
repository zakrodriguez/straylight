# vagrant/lib/lab_profile.rb
#
# Resolver for the composable-lab profile system. Loaded by the Vagrantfile
# at parse time. Returns the active profile's component list + per-VM
# resource overrides + derived dotfile/VBox naming.
#
# Resolution priority (highest first):
#   1. LAB_COMPONENTS env var (CSV — explicit override, "custom" profile)
#   2. LAB_PROFILE env var (named profile from vagrant/profiles/)
#   3. LAB_PROFILE from vagrant/.env (loaded by lib/lab_env.rb — wizard path)
#   4. 'core' (default)
#
# Note: the legacy ADCS_TOPOLOGY env var was removed after a deprecation
# period. If we detect it set without LAB_PROFILE we abort with a
# migration hint rather than silently mis-resolving.

require 'yaml'
require_relative 'topology'
require_relative 'lab_env'

module LabProfile
  PROFILES_DIR  = File.expand_path('../profiles', __dir__)

  # Master VM inventory — derived from topology.yml (the single source of
  # truth). Drift is caught by
  # test/topology_test.rb#test_valid_components_matches_topology.
  VALID_COMPONENTS = Topology.names.freeze

  # Resolves the active profile from environment variables.
  # Returns a hash with: :name, :components, :resources,
  # :dotfile_dir, :vbox_prefix, :source (one of :lab_components,
  # :lab_profile, :dotenv, :default).
  def self.resolve
    if ENV['LAB_COMPONENTS'] && !ENV['LAB_COMPONENTS'].strip.empty?
      components = parse_csv(ENV['LAB_COMPONENTS'])
      validate_components!(components, source: 'LAB_COMPONENTS')
      return {
        name: 'custom',
        components: components,
        resources: {},
        dotfile_dir: '.vagrant-custom',
        vbox_prefix: 'straylight-custom',
        source: :lab_components,
        description: 'Ad-hoc component list from LAB_COMPONENTS env var',
      }
    end

    profile_name, source = resolve_profile_name
    raise ArgumentError, "invalid profile name: #{profile_name}" unless profile_name =~ /\A[a-z0-9_-]+\z/i
    yaml_path = File.join(PROFILES_DIR, "#{profile_name}.yml")

    unless File.exist?(yaml_path)
      raise "Profile not found: #{yaml_path}\n" \
            "Available profiles: #{available_profiles.join(', ')}\n" \
            "Or set LAB_COMPONENTS=vm1,vm2,... for an ad-hoc list."
    end

    yaml = YAML.load_file(yaml_path)
    components = yaml.fetch('components', [])
    resources = yaml.fetch('resources', {}) || {}

    validate_components!(components, source: "profile '#{profile_name}'")
    validate_resources!(resources, components, profile_name)

    {
      name: profile_name,
      components: components,
      resources: resources,
      dotfile_dir: ".vagrant-#{profile_name}",
      vbox_prefix: "straylight-#{profile_name}",
      source: source,
      description: yaml.fetch('description', '').to_s.strip,
    }
  end

  # Returns sorted list of profile names available in vagrant/profiles/.
  def self.available_profiles
    Dir.glob(File.join(PROFILES_DIR, '*.yml'))
       .map { |p| File.basename(p, '.yml') }
       .sort
  end

  # Per-VM resource lookup helpers — use in Vagrantfile alongside the
  # default value. e.g.: `vb.memory = LabProfile.mem(RESOURCES, 'dc1', 2048)`
  # Returns the profile's override if present, otherwise the default.
  def self.mem(resources, vm_name, default)
    (resources[vm_name] || {})['memory'] || default
  end

  def self.cpus(resources, vm_name, default)
    (resources[vm_name] || {})['cpus'] || default
  end

  # ── Internal helpers ─────────────────────────────────────────────

  def self.resolve_profile_name
    if ENV['LAB_PROFILE'] && !ENV['LAB_PROFILE'].strip.empty?
      source = LabEnv.loaded_keys.include?('LAB_PROFILE') ? :dotenv : :lab_profile
      return [ENV['LAB_PROFILE'], source]
    end

    # ADCS_TOPOLOGY was supported as a deprecated alias during the
    # composable-lab transition and is now removed. Hard-error so a
    # stale .env or shell export doesn't silently fall back to 'core'.
    if ENV['ADCS_TOPOLOGY'] && !ENV['ADCS_TOPOLOGY'].strip.empty?
      hint = case ENV['ADCS_TOPOLOGY']
             when 'one-tier' then 'LAB_PROFILE=ad-cs-one-tier'
             when 'two-tier' then 'LAB_PROFILE=ad-cs-two-tier'
             else 'LAB_PROFILE=<name> — see `bash up.sh --list-profiles`'
             end
      raise "ADCS_TOPOLOGY env var was removed (composable-lab refactor). " \
            "Use #{hint} instead. " \
            "If this came from vagrant/.env, edit the file or re-run scripts/install-wizard.sh."
    end

    ['core', :default]
  end

  def self.parse_csv(s)
    s.split(',').map(&:strip).reject(&:empty?)
  end

  def self.validate_components!(components, source:)
    if components.empty?
      raise "Empty components list (source: #{source}). Profiles must list at least one VM."
    end
    invalid = components - VALID_COMPONENTS
    return if invalid.empty?
    raise "Unknown component(s) in #{source}: #{invalid.inspect}\n" \
          "Valid components: #{VALID_COMPONENTS.join(', ')}"
  end

  def self.validate_resources!(resources, components, profile_name)
    return if resources.nil? || resources.empty?
    extras = resources.keys - components
    return if extras.empty?
    raise "Profile '#{profile_name}' has resource overrides for VMs not in components: #{extras.inspect}"
  end
end
