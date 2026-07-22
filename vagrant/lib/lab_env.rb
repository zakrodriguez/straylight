# vagrant/lib/lab_env.rb
#
# Loads vagrant/.env (written by scripts/install-wizard.sh) into ENV for
# any key not already set in the real environment.
#
# Why this exists: bash `source` of a bare KEY=VALUE file creates shell
# variables, not environment variables. Child processes — the Vagrantfile
# parse, the lab_profile resolver invoked by scripts/lib/profile-helper.sh —
# never saw wizard-selected values, so a wizard-chosen profile silently
# resolved to the 'core' default.
#
# Precedence: real environment variables always win. An inline
# `LAB_PROFILE=x vagrant up` or `LAB_PROFILE=x bash up.sh` overrides the
# file; an empty-string env var counts as unset (matching the resolver's
# own strip.empty? semantics).
#
# Loaded automatically on require (bottom of this file).
module LabEnv
  DOTENV_PATH = File.expand_path('../.env', __dir__)

  # Keys whose values came from the .env file rather than the real
  # environment. lab_profile.rb uses this to report source=:dotenv.
  def self.loaded_keys
    @loaded_keys ||= []
  end

  def self.load!(path = DOTENV_PATH)
    return loaded_keys unless File.file?(path)
    File.readlines(path).each do |raw|
      line = raw.strip
      next if line.empty? || line.start_with?('#')
      line = line.sub(/\Aexport\s+/, '')
      key, sep, value = line.partition('=')
      next if sep.empty?
      key = key.strip
      next unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      next if ENV[key] && !ENV[key].empty?
      value = value.strip
      if value.length >= 2 && %w[" '].include?(value[0]) && value[-1] == value[0]
        value = value[1..-2]
      end
      ENV[key] = value
      loaded_keys << key unless loaded_keys.include?(key)
    end
    loaded_keys
  end
end

LabEnv.load!
