#!/bin/bash
# profile-helper.sh — sourced by up.sh / clean.sh / nuke.sh / snap.sh.
# Resolves the active LAB_PROFILE via the same Ruby resolver the
# Vagrantfile uses, then exports bash-friendly variables:
#
#   LAB_PROFILE_NAME       — resolved profile name (e.g. "pqc-linux", "custom")
#   LAB_PROFILE_SOURCE     — :lab_components | :lab_profile | :dotenv | :default
#   LAB_PROFILE_COMPONENTS — comma-separated component list
#   LAB_PROFILE_COMPONENTS_ARR — bash array of components
#   LAB_DOTFILE_DIR        — .vagrant-<name>
#   LAB_VBOX_PREFIX        — straylight-<name>
#   VAGRANT_DOTFILE_PATH   — exported = LAB_DOTFILE_DIR (vagrant respects this)
#
# Usage:
#   source "$(dirname "$0")/lib/profile-helper.sh"
#   echo "Building components: ${LAB_PROFILE_COMPONENTS_ARR[*]}"
#
# Side effects:
#   - exports VAGRANT_DOTFILE_PATH (so subsequent `vagrant ...` calls in the
#     same script use the per-profile dotfile dir without each command setting it)

set -uo pipefail

_PROFILE_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Capture stdout (KEY=VALUE pairs) separately from stderr. The resolver
# raises on bad input (e.g. stale ADCS_TOPOLOGY) which we surface to the
# user verbatim rather than evaluating as bash.
#
# Use temp files + `|| _rc=$?` rather than `_eval=$(ruby ...)` because the
# calling script may have `set -e` active. With `set -e`, a failing command
# substitution kills the shell immediately, before this file's own error
# handler runs. `cmd || _rc=$?` is an explicit exemption to `set -e`.
_helper_tmp_out=$(mktemp)
_helper_tmp_err=$(mktemp)
# Clean up the temp files on every return path from this sourced file (the
# explicit rm -f calls below stay for the exit-1 path, which RETURN can't
# catch; rm -f is idempotent so the double-removal is harmless).
trap 'rm -f "$_helper_tmp_out" "$_helper_tmp_err"' RETURN
_rc=0
ruby -I "$_PROFILE_HELPER_DIR/lib" -r lab_profile -r lab_network -e '
  begin
    p = LabProfile.resolve
  rescue => e
    $stderr.puts "[profile-helper] resolution failed: #{e.message.lines.first}"
    exit 1
  end
  puts "LAB_PROFILE_NAME=#{p[:name]}"
  puts "LAB_PROFILE_SOURCE=#{p[:source]}"
  puts "LAB_PROFILE_COMPONENTS=#{p[:components].join(",")}"
  puts "LAB_DOTFILE_DIR=#{p[:dotfile_dir]}"
  puts "LAB_VBOX_PREFIX=#{p[:vbox_prefix]}"
  # Skip the (VBoxManage-heavy) allocator when LAB_NETWORK is an explicit
  # non-base override — its value would just be discarded by the := below. We
  # still allocate when unset OR pinned to the base .56, so the stale-.env
  # warning downstream can compare against the dynamic value.
  net = if !ENV["LAB_NETWORK"].to_s.strip.empty? && ENV["LAB_NETWORK"] != "192.168.56"
          ENV["LAB_NETWORK"]
        else
          own = p[:components].map { |c| "#{p[:vbox_prefix]}-#{c}" }
          LabNetwork.for_lab(p[:vbox_prefix], own_vms: own)
        end
  puts "LAB_PROFILE_NETWORK=#{net}"
  ' >"$_helper_tmp_out" 2>"$_helper_tmp_err" || _rc=$?

# Forward any stderr (warnings / errors) to the user's stderr.
[[ -s "$_helper_tmp_err" ]] && cat "$_helper_tmp_err" >&2

if [[ $_rc -ne 0 ]]; then
  rm -f "$_helper_tmp_out" "$_helper_tmp_err"
  # We're sourced — `return` would just return from this file and let the
  # caller continue with unbound LAB_PROFILE_* vars. Exit hard so a stale
  # ADCS_TOPOLOGY doesn't produce a confusing "unbound variable" cascade.
  exit 1
fi

_eval=$(cat "$_helper_tmp_out")
rm -f "$_helper_tmp_out" "$_helper_tmp_err"
eval "$_eval"

# Per-profile host-only /24. Use := so an explicit shell/.env LAB_NETWORK (set
# before this file is sourced) still wins; otherwise adopt the profile's network.
# This makes every sourcing consumer (up.sh and the validate.sh it invokes)
# subnet-aware without each needing the Ruby resolver.
: "${LAB_NETWORK:=$LAB_PROFILE_NETWORK}"
export LAB_NETWORK

# Stale-.env guard: LAB_NETWORK pinned to the base .56 while this lab would
# otherwise be allocated a different /24 is the tell-tale of a legacy
# `LAB_NETWORK=192.168.56` line baked into vagrant/.env by an old install-wizard.
# Left in place it silently re-collides concurrent labs. (Heuristic — an
# intentional base pin trips it too; harmless to ignore.)
if [[ "$LAB_NETWORK" == "192.168.56" && "$LAB_PROFILE_NETWORK" != "192.168.56" ]]; then
  echo "[profile-helper] note: LAB_NETWORK is pinned to 192.168.56 but this lab" \
       "would otherwise use $LAB_PROFILE_NETWORK. Remove a stale 'LAB_NETWORK=192.168.56'" \
       "line from vagrant/.env to enable per-lab subnets." >&2
fi

# Build bash array from CSV
IFS=',' read -ra LAB_PROFILE_COMPONENTS_ARR <<< "$LAB_PROFILE_COMPONENTS"

# Export the dotfile path so subsequent vagrant invocations in this shell
# pick up the per-profile state dir without each command setting it.
#
# Fallback: if LAB_DOTFILE_DIR has no machine state but the default `.vagrant/`
# does AND running VBox VMs match this profile's prefix, prefer `.vagrant/`.
# Happens when someone runs bare `vagrant up` (no VAGRANT_DOTFILE_PATH) for a
# non-default profile — Vagrant defaults state to .vagrant/ while the
# Vagrantfile still uses the profile's VBox naming. Without this, validate.sh
# / clean.sh / snap.sh look in the empty LAB_DOTFILE_DIR and report "no VMs".
_dotfile_has_machine_state() {
  local dir="$1"
  [[ -d "$dir/machines" ]] || return 1
  # Any machine subdir with a non-empty id file → has live state. Can't just
  # check the first alphabetical entry — Vagrant leaves stub dirs for VMs that
  # were destroyed (e.g., acme1) so the first dir may have no id file even
  # when other machines are tracked.
  find "$dir/machines" -mindepth 3 -maxdepth 3 -name id -type f \! -empty 2>/dev/null \
    | head -1 | grep -q .
}

if ! _dotfile_has_machine_state "$LAB_DOTFILE_DIR" \
   && _dotfile_has_machine_state ".vagrant" \
   && command -v VBoxManage >/dev/null 2>&1 \
   && VBoxManage list runningvms 2>/dev/null | grep -q "\"${LAB_VBOX_PREFIX}-"; then
  echo "[profile-helper] note: $LAB_DOTFILE_DIR has no machine state but" \
       ".vagrant/ tracks running ${LAB_VBOX_PREFIX}-* VMs. Using .vagrant/." >&2
  export VAGRANT_DOTFILE_PATH=".vagrant"
else
  export VAGRANT_DOTFILE_PATH="$LAB_DOTFILE_DIR"
fi

# Helper: returns 0 if $1 is in the active profile's components, else 1.
profile_has() {
  local needle="$1"
  for c in "${LAB_PROFILE_COMPONENTS_ARR[@]}"; do
    [[ "$c" == "$needle" ]] && return 0
  done
  return 1
}

# Helper: list every available profile name on a single line.
list_profiles() {
  ruby -I "$_PROFILE_HELPER_DIR/lib" -r lab_profile -e '
    LabProfile.available_profiles.each do |name|
      yaml_path = File.join(LabProfile::PROFILES_DIR, "#{name}.yml")
      desc = (YAML.load_file(yaml_path)["description"] || "").strip.lines.first.to_s.strip
      puts "  #{name.ljust(22)} #{desc}"
    end
  '
}
