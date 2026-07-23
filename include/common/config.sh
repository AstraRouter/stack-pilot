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

# Refuse to `source` a config file that an unprivileged user could have tampered
# with while we run as root (that would be arbitrary code execution as root).
assert_config_file_trusted() {
  local file="$1" mode owner
  [[ -e "${file}" ]] || return 0
  # Only enforce under root; a normal user sourcing their own config is their own risk.
  [[ "$(id -u)" == "0" ]] || return 0
  mode="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || echo '')"
  if [[ -n "${mode}" ]] && (( 8#${mode} & 0022 )); then
    die "Refusing to load ${file}: it is group/world-writable while running as root (run: chmod go-w '${file}')"
  fi
  owner="$(stat -c '%u' "${file}" 2>/dev/null || stat -f '%u' "${file}" 2>/dev/null || echo '')"
  if [[ -n "${owner}" && "${owner}" != "0" && "${owner}" != "${SUDO_UID:-x}" ]]; then
    die "Refusing to load ${file}: owned by uid ${owner}, not root or the sudo invoker, while running as root"
  fi
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
  assert_config_file_trusted "${options_file}"
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
  assert_config_file_trusted "${versions_file}"
  # shellcheck disable=SC1090
  source "${versions_file}"
}
