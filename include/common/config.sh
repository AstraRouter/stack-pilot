#!/usr/bin/env bash

get_config_value() {
  local file="$1"
  local key="$2"
  bash -c 'source "$1"; key="$2"; [[ ${!key+x} ]] || exit 1; printf "%s" "${!key}"' _ "${file}" "${key}"
}

shell_quote_config_value() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

set_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp quoted_value
  quoted_value="$(shell_quote_config_value "${value}")"
  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${quoted_value}" '
    BEGIN { found=0 }
    $0 ~ "^[[:space:]]*" key "=" {
      print key "=" value
      found=1
      next
    }
    { print }
    END {
      if (!found) print key "=" value
    }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

load_options() {
  local options_file="${1:-${LNMP_ROOT_DIR}/options.conf}"
  local example_file="${LNMP_OPTIONS_EXAMPLE_FILE:-${LNMP_ROOT_DIR}/options.example.conf}"
  if [[ ! -f "${options_file}" ]]; then
    [[ -f "${example_file}" ]] || die "Options file not found: ${options_file}; example file not found: ${example_file}"
    cp "${example_file}" "${options_file}"
    chmod 600 "${options_file}" 2>/dev/null || true
    info "Created private runtime configuration: ${options_file}"
  fi
  LNMP_OPTIONS_FILE="${options_file}"
  # shellcheck disable=SC1090
  source "${options_file}"
  if declare -F refresh_component_version_urls >/dev/null; then
    refresh_component_version_urls || die "options.conf contains an unsupported component version"
  fi
  user="${user:-www}"
  group="${group:-www}"
  mysql_password="${mysql_password:-}"
  mariadb_password="${mariadb_password:-}"
}

load_versions() {
  local versions_file="${1:-${LNMP_ROOT_DIR}/versions.conf}"
  [[ -f "${versions_file}" ]] || die "Version file not found: ${versions_file}"
  # shellcheck disable=SC1090
  source "${versions_file}"
}
