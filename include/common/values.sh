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

normalize_php_versions() {
  local input="${1:-}"
  local token version result seen
  input="${input//,/ }"
  result=""
  seen=" "
  for token in ${input}; do
    version="${token//./}"
    case "${version}" in
      54|55|56|70|71|72|73|74|80|81|82|83|84|85) ;;
      *) return 1 ;;
    esac
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

validate_port() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  ((10#${port} >= 1 && 10#${port} <= 65535))
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
  local version="$1"
  version="${version//./}"
  case "${version}" in
    54|55|56|70|71|72|73|74|80|81|82|83|84|85) printf '90%s' "${version}" ;;
    *) return 1 ;;
  esac
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
