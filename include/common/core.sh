#!/usr/bin/env bash

info() { printf '%s\n' "${C_BLUE}$*${C_RESET}"; }
ok() { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}$*${C_RESET}" >&2; }
die() { printf '%s\n' "${C_RED}Error: $*${C_RESET}" >&2; exit 1; }

require_root() {
  [[ "${LNMP_ALLOW_NON_ROOT:-}" == "1" ]] && return 0
  [[ "$(id -u)" == "0" ]] || die "Run this script as root"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

random_password() {
  local length="${1:-16}"
  local value=""
  while ((${#value} < length)); do
    value+="$({ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$((length - ${#value}))"; } 2>/dev/null || true)"
  done
  printf '%s' "${value}"
}

validate_password_or_random() {
  local value="$1"
  local min_length="${2:-6}"
  [[ -z "${value}" ]] && return 0
  [[ ${#value} -ge min_length ]] || return 1
  [[ "${value}" != *"'"* ]] || return 1
  [[ "${value}" != *"\\"* ]] || return 1
}

validate_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
