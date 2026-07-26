#!/usr/bin/env bash

normalize_yes_no() {
  local input="${1:-}"
  local default="${2:-y}"
  input="$(printf '%s' "${input}" | tr '[:upper:]' '[:lower:]')"
  [[ -z "${input}" ]] && input="${default}"
  case "${input}" in
    y|yes) printf 'y' ;;
    n|no) printf 'n' ;;
    *) return 1 ;;
  esac
}

validate_choice() {
  local choice="$1"
  local choices="$2"
  local item
  for item in ${choices}; do
    [[ "${choice}" == "${item}" ]] && return 0
  done
  return 1
}

select_default_index() {
  local default="$1"
  shift
  local index=0
  local entry value
  for entry in "$@"; do
    value="${entry%%|*}"
    if [[ "${value}" == "${default}" ]]; then
      printf '%s' "${index}"
      return 0
    fi
    index=$((index + 1))
  done
  printf '0'
}

toggle_multi_value() {
  local selected="${1:-}"
  local value="$2"
  local item result found="n"
  result=""
  for item in ${selected}; do
    if [[ "${item}" == "${value}" ]]; then
      found="y"
      continue
    fi
    result="${result:+${result} }${item}"
  done
  if [[ "${found}" == "n" ]]; then
    result="${result:+${result} }${value}"
  fi
  printf '%s' "${result}"
}

entry_value() {
  printf '%s' "${1%%|*}"
}

entry_label() {
  local entry="$1"
  if [[ "${entry}" == *"|"* ]]; then
    printf '%s' "${entry#*|}"
  else
    printf '%s' "${entry}"
  fi
}

# Single source of truth for the PHP versions this tool can build. The
# installer, the vhost menu, and the service menu all derive their choices from
# it, so a version added in only one place cannot produce a build that is never
# offered, or an offer that cannot be built.
php_supported_versions() {
  printf '54 55 56 70 71 72 73 74 80 81 82 83 84 85'
}

php_version_supported() {
  local version="${1//./}" candidate
  [[ -n "${version}" ]] || return 1
  for candidate in $(php_supported_versions); do
    [[ "${version}" == "${candidate}" ]] && return 0
  done
  return 1
}

php_version_entries() {
  local version
  for version in $(php_supported_versions); do
    printf '%s|PHP %s\n' "${version}" "$(php_version_label "${version}")"
  done
}

normalize_php_versions() {
  local input="${1:-}"
  local token version result seen
  input="${input//,/ }"
  result=""
  seen=" "
  for token in ${input}; do
    version="${token//./}"
    php_version_supported "${version}" || return 1
    if [[ "${seen}" != *" ${version} "* ]]; then
      result="${result:+${result} }${version}"
      seen+="${version} "
    fi
  done
  [[ -n "${result}" ]] || return 1
  printf '%s' "${result}"
}

normalize_values() {
  local input="${1:-}"
  local allowed="$2"
  local token result seen
  input="${input//,/ }"
  result=""
  seen=" "
  for token in ${input}; do
    validate_choice "${token}" "${allowed}" || return 1
    if [[ "${seen}" != *" ${token} "* ]]; then
      result="${result:+${result} }${token}"
      seen+="${token} "
    fi
  done
  [[ -n "${result}" ]] || return 1
  printf '%s' "${result}"
}

normalize_component_version() {
  local selected="$1" supported="$2"
  validate_choice "${selected}" "${supported}" || return 1
  printf '%s' "${selected}"
}

# Redis stores its password as a bare token in `requirepass <value>` and in a
# systemd EnvironmentFile. Whitespace splits the directive, `#` starts a
# comment, a newline injects a directive, and quotes/backslash/`$` are
# reinterpreted by systemd. An empty value disables authentication.
validate_redis_password() {
  local value="${1:-}"
  [[ -z "${value}" ]] && return 0
  [[ ${#value} -ge 6 ]] || return 1
  [[ ${#value} -le 512 ]] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9._~!@%^*+=:,/-]+$ ]]
}

# Bind addresses are interpolated unquoted into systemd units and service
# configuration, so restrict them to characters that cannot introduce an extra
# command-line argument. A leading hyphen is rejected for the same reason;
# IPv6 literals may start with a colon.
validate_bind_address() {
  local value="${1:-}"
  [[ -n "${value}" ]] || return 1
  [[ ${#value} -le 255 ]] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9:][A-Za-z0-9._:-]*$ ]]
}

# Memory sizes in MB. Bounded so the value cannot carry extra systemd arguments
# and cannot overflow 64-bit arithmetic.
validate_memory_mb() {
  local value="${1:-}"
  [[ "${value}" =~ ^0*([0-9]{1,7})$ ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 1048576))
}

validate_port() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  # Bound the digit count before comparing: bash arithmetic is 64-bit and wraps
  # silently, so a 20-digit value could otherwise land back inside 1-65535.
  # Leading zeros stay acceptable, so 080 is still port 80.
  [[ "${port}" =~ ^0*([0-9]{1,5})$ ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 65535))
}

# Service accounts are interpolated unquoted into nginx.conf ("user X Y;"),
# php-fpm.d/www.conf, and ./configure --with-fpm-user=, and are passed to
# useradd. Anything outside the portable POSIX account character set can break
# those files or inject a second directive. useradd itself accepts at most 32
# characters.
validate_unix_username() {
  local value="${1:-}"
  [[ ${#value} -le 32 ]] || return 1
  [[ "${value}" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

# PHP-FPM pool process managers. Any other value makes php-fpm refuse to start.
validate_php_pm_mode() {
  case "${1:-}" in
    static|dynamic|ondemand) return 0 ;;
  esac
  return 1
}

# A bounded positive integer, for pool sizes and timeouts. The digit count is
# capped before the comparison because bash arithmetic is 64-bit and wraps.
validate_positive_integer() {
  local value="${1:-}" max="${2:-65535}"
  [[ "${value}" =~ ^0*([0-9]{1,9})$ ]] || return 1
  ((10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= max))
}

# Normalize a PHP-style byte size (50M, 1024K, 2G, or a plain byte count) into
# the lowercase form Nginx expects. Rejects anything else, because these values
# reach php-fpm.d/www.conf and nginx.conf unquoted.
normalize_size_value() {
  local value="${1:-}" number unit
  [[ "${value}" =~ ^0*([0-9]{1,12})([KkMmGg]?)$ ]] || return 1
  number="$((10#${BASH_REMATCH[1]}))"
  unit="${BASH_REMATCH[2]}"
  ((number > 0)) || return 1
  case "${unit}" in
    [Kk]) printf '%sk' "${number}" ;;
    [Mm]) printf '%sm' "${number}" ;;
    [Gg]) printf '%sg' "${number}" ;;
    *) printf '%s' "${number}" ;;
  esac
}

validate_size_value() {
  normalize_size_value "${1:-}" >/dev/null
}

# Time zone names reach php.ini and timedatectl. Restrict them to the IANA
# database's own character set so neither can be given an extra argument.
validate_timezone() {
  local value="${1:-}"
  [[ -n "${value}" ]] || return 1
  [[ ${#value} -le 64 ]] || return 1
  [[ "${value}" != *".."* ]] || return 1
  [[ "${value}" =~ ^[A-Za-z][A-Za-z0-9._+-]*(/[A-Za-z0-9._+-]+)*$ ]]
}

component_version_marker_path() {
  printf '%s/.stack-pilot-version' "$1"
}

read_component_version_marker() {
  local marker
  marker="$(component_version_marker_path "$1")"
  [[ -f "${marker}" ]] || return 1
  tr -d '[:space:]' < "${marker}"
}

write_component_version_marker() {
  local install_dir="$1" version="$2"
  mkdir -p "${install_dir}"
  printf '%s\n' "${version}" > "$(component_version_marker_path "${install_dir}")"
}

extract_semver() {
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Compare two dotted version strings numerically. Prints -1, 0, or 1 for
# "less than", "equal", and "greater than". Missing components count as zero,
# so 1.26 and 1.26.0 compare equal.
compare_versions() {
  local left="$1" right="$2"
  local -a left_parts right_parts
  local index count left_part right_part
  IFS='.' read -r -a left_parts <<< "${left}"
  IFS='.' read -r -a right_parts <<< "${right}"
  count=${#left_parts[@]}
  ((${#right_parts[@]} > count)) && count=${#right_parts[@]}
  for ((index = 0; index < count; index++)); do
    left_part="${left_parts[index]:-0}"
    right_part="${right_parts[index]:-0}"
    # Non-numeric suffixes (rc1, beta) are ignored rather than aborting.
    left_part="${left_part//[!0-9]/}"
    right_part="${right_part//[!0-9]/}"
    ((10#${left_part:-0} > 10#${right_part:-0})) && { printf '1'; return 0; }
    ((10#${left_part:-0} < 10#${right_part:-0})) && { printf -- '-1'; return 0; }
  done
  printf '0'
}

# An upgrade to an older version is almost always an edited versions.conf
# rather than an intent to roll back, and it silently replaces a newer build.
assert_not_a_downgrade() {
  local label="$1" installed="$2" selected="$3"
  [[ -n "${installed}" && -n "${selected}" ]] || return 0
  [[ "$(compare_versions "${selected}" "${installed}")" == "-1" ]] || return 0
  warn "${label} ${installed} is installed but ${selected} is selected, which is a downgrade."
  warn "Check versions.conf. A downgrade can leave data or configuration written by the newer version unreadable."
  [[ "${LNMP_ALLOW_DOWNGRADE:-0}" == "1" ]] ||
    die "Refusing to downgrade ${label} from ${installed} to ${selected}; set LNMP_ALLOW_DOWNGRADE=1 to override"
}

verify_or_adopt_component_version() {
  local label="$1" install_dir="$2" selected="$3" detected="$4" recorded
  recorded="$(read_component_version_marker "${install_dir}" 2>/dev/null || true)"
  [[ -n "${recorded}" ]] || recorded="${detected}"
  [[ -n "${recorded}" ]] || die "Unable to identify the installed ${label} version in ${install_dir}; verify it before upgrading"
  [[ "${recorded}" == "${selected}" ]] || die "Installed ${label} version is ${recorded}, but ${selected} is selected. Use the upgrade workflow instead of overwriting the existing directory"
  [[ -f "$(component_version_marker_path "${install_dir}")" ]] || write_component_version_marker "${install_dir}" "${selected}"
}

should_skip_completed_install() {
  local label="$1" install_dir="$2" selected="$3" detected="$4"
  if [[ "${LNMP_FORCE_REINSTALL:-0}" == "1" ]]; then
    warn "${label} is installed and will be rebuilt for the explicit upgrade request: ${selected}"
    return 1
  fi
  verify_or_adopt_component_version "${label}" "${install_dir}" "${selected}" "${detected}"
  return 0
}

php_fpm_port() {
  local version="${1//./}"
  php_version_supported "${version}" || return 1
  printf '90%s' "${version}"
}

php_version_label() {
  local version="${1//./}"
  printf '%s.%s' "${version:0:1}" "${version:1:1}"
}

php_install_dir_for_version() {
  local version="${1//./}"
  printf '%s/%s' "${php_install_base:-/usr/local/services/php}" "${version}"
}

php_service_name() {
  local version="${1//./}"
  printf 'php%s-fpm' "${version}"
}

switch_cli_php_version() {
  local version="${1//./}"
  local prefix bin_dir bin
  prefix="$(php_install_dir_for_version "${version}")"
  bin_dir="${LNMP_CLI_BIN_DIR:-/usr/local/bin}"
  [[ -x "${prefix}/bin/php" ]] || die "PHP CLI not found: ${prefix}/bin/php"
  mkdir -p "${bin_dir}"
  for bin in php phpize php-config pecl pear; do
    if [[ -x "${prefix}/bin/${bin}" ]]; then
      ln -sfn "${prefix}/bin/${bin}" "${bin_dir}/${bin}"
    fi
  done
  ok "Default CLI PHP switched to ${version}: ${prefix}/bin/php"
}

link_executable_to_bin() {
  local target="$1"
  local name="${2:-$(basename "${target}")}"
  local bin_dir="${LNMP_CLI_BIN_DIR:-/usr/local/bin}"
  [[ -x "${target}" ]] || return 0
  mkdir -p "${bin_dir}"
  ln -sfn "${target}" "${bin_dir}/${name}"
}

port_list_add_unique() {
  local list="${1:-}"
  local port="${2:-}"
  local item
  if [[ -z "${port}" ]]; then
    printf '%s' "${list}"
    return 0
  fi
  for item in ${list}; do
    if [[ "${item}" == "${port}" ]]; then
      printf '%s' "${list}"
      return 0
    fi
  done
  printf '%s' "${list:+${list} }${port}"
}
