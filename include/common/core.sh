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

# Quote a value as a SQL string literal (doubles embedded single quotes).
sql_quote_literal() {
  local value="$1"
  value="$(printf '%s' "${value}" | sed "s/'/''/g")"
  printf "'%s'" "${value}"
}

# Wait until a MySQL/MariaDB server accepts socket connections as root.
wait_for_database_ready() {
  local client="$1" socket="$2" attempts="${3:-60}" i
  for i in $(seq 1 "${attempts}"); do
    if [[ -S "${socket}" ]] && "${client}" -uroot -S "${socket}" -e "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Number of parallel make jobs, capped by available memory (~1 job per 512 MB)
# to avoid the OOM killer on small VPSes. Floor 1, ceiling = CPU count.
build_parallelism() {
  local cpus mem_kb mem_cap
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  [[ "${cpus}" =~ ^[0-9]+$ ]] && ((cpus >= 1)) || cpus=1
  if [[ -r /proc/meminfo ]]; then
    mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ "${mem_kb}" =~ ^[0-9]+$ ]] || mem_kb=0
    if ((mem_kb > 0)); then
      mem_cap=$((mem_kb / 524288))
      ((mem_cap >= 1)) || mem_cap=1
      ((mem_cap < cpus)) && cpus="${mem_cap}"
    fi
  fi
  printf '%s' "${cpus}"
}

# Create a disk-backed build directory (never tmpfs/RAM): building under /tmp
# risks OOM/ENOSPC when /tmp is RAM-backed. Caller removes it when done.
make_build_dir() {
  local base="${LNMP_SRC_DIR:-/tmp}/build"
  mkdir -p "${base}"
  mktemp -d "${base}/XXXXXX"
}

# Validate a filesystem path supplied by the user before it is written into a
# config file or used with rm/mkdir: absolute, no traversal, no whitespace or
# shell/Nginx metacharacters.
validate_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 1
  [[ "${path}" == /* ]] || return 1
  [[ ${#path} -le 4096 ]] || return 1
  [[ "${path}" != *'/../'* && "${path}" != */.. ]] || return 1
  [[ "${path}" =~ ^[A-Za-z0-9._/-]+$ ]]
}
