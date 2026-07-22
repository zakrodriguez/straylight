#!/bin/bash
# scripts/lib/colors.sh — single ANSI palette for all lab scripts.
# Source once; respects NO_COLOR and non-tty stdout.
[[ -n "${_LAB_COLORS_LOADED:-}" ]] && return 0
_LAB_COLORS_LOADED=1
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""; C_BOLD=""
else
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
fi
