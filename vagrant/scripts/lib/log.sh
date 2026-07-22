#!/bin/bash
# scripts/lib/log.sh — shared logging helpers. Source after colors.sh.
[[ -n "${_LAB_LOG_LOADED:-}" ]] && return 0
_LAB_LOG_LOADED=1
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_here/colors.sh"
log_info()  { printf '%s\n' "${C_CYAN}$*${C_RESET}"; }
log_ok()    { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
log_warn()  { printf '%s\n' "${C_YELLOW}$*${C_RESET}" >&2; }
log_err()   { printf '%s\n' "${C_RED}$*${C_RESET}" >&2; }
log_step()  { printf '%s\n' "${C_BOLD}== $* ==${C_RESET}"; }
