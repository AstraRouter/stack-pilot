#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
load_options
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/uninstall_lib.sh"

show_uninstall_help() {
  cat <<'EOF'
Usage: ./uninstall.sh

Supports selective and complete removal. Databases, Redis data, sites, certificates, logs, and source caches are preserved by default.
EOF
}

case "${1:-}" in
  -h|--help) show_uninstall_help; exit 0 ;;
  "") ;;
  *) warn "uninstall.sh does not accept operation arguments; opening the interactive menu." ;;
esac

select_uninstall_components() {
  prompt_multi_select "Select components to uninstall" "nginx" \
    "nginx|Nginx" \
    "php|PHP (select versions on the next page)" \
    "mysql|MySQL" \
    "mariadb|MariaDB" \
    "redis|Redis" \
    "memcached|Memcached" \
    "certbot|Certbot certificate tool" \
    "composer|Composer"
}

select_php_versions_to_uninstall() {
  local installed entries=() version
  installed="$(installed_php_versions)"
  [[ -n "${installed}" ]] || { warn "No installed PHP versions were found"; return 0; }
  for version in ${installed}; do
    entries+=("${version}|PHP $(php_version_label "${version}")")
  done
  prompt_multi_select "Select PHP versions to uninstall" "${installed%% *}" "${entries[@]}"
}

print_uninstall_summary() {
  local component
  echo
  echo "Uninstall plan:"
  for component in ${selected_components}; do
    if [[ "${component}" == "php" ]]; then
      echo "  - PHP: ${selected_php_versions:-not installed}"
    else
      echo "  - $(uninstall_component_label "${component}")"
    fi
  done
  echo "  Remove application data: ${UNINSTALL_REMOVE_DATA}"
  echo "  Remove website directory: ${UNINSTALL_REMOVE_WWW}"
  echo "  Remove logs: ${UNINSTALL_REMOVE_LOGS}"
  echo "  Remove certificates: ${UNINSTALL_REMOVE_CERTIFICATES}"
  echo "  Remove source cache: ${UNINSTALL_REMOVE_SOURCES}"
}

require_root
print_header
while :; do
  mode="$(prompt_select "Select the uninstall mode" "selective" \
    "selective|Selective uninstall" \
    "all|Uninstall everything" \
    "exit|Exit")"
  [[ "${mode}" != "exit" ]] || exit 0

  selected_php_versions=""
  if [[ "${mode}" == "all" ]]; then
    selected_components="nginx php mysql mariadb redis memcached certbot composer"
    selected_php_versions="$(installed_php_versions 2>/dev/null || true)"
    break
  fi

  while :; do
    selected_components="$(LNMP_ALLOW_BACK=1 select_uninstall_components)"
    [[ "${selected_components}" == "__BACK__" ]] && break
    if [[ " ${selected_components} " == *" php "* ]]; then
      selected_php_versions="$(LNMP_ALLOW_BACK=1 select_php_versions_to_uninstall)"
      [[ "${selected_php_versions}" == "__BACK__" ]] && continue
    fi
    break 2
  done
done

UNINSTALL_REMOVE_DATA="$(prompt_yes_no "Remove database, Redis, and Memcached data" "n")"
UNINSTALL_REMOVE_WWW="$(prompt_yes_no "Remove the website directory ${wwwroot_dir}" "n")"
UNINSTALL_REMOVE_LOGS="$(prompt_yes_no "Remove component logs" "n")"
UNINSTALL_REMOVE_CERTIFICATES="$(prompt_yes_no "Remove Let's Encrypt certificates" "n")"
UNINSTALL_REMOVE_SOURCES="$(prompt_yes_no "Remove downloaded source caches" "n")"

if [[ "${UNINSTALL_REMOVE_DATA}${UNINSTALL_REMOVE_WWW}${UNINSTALL_REMOVE_CERTIFICATES}" == *y* ]]; then
  delete_confirm="$(prompt_input "Application data will be removed; type DELETE to confirm" "")"
  [[ "${delete_confirm}" == "DELETE" ]] || die "Application data removal was not confirmed; uninstall cancelled"
fi

print_uninstall_summary
final_confirm="$(prompt_input "Type UNINSTALL to execute the plan above" "")"
[[ "${final_confirm}" == "UNINSTALL" ]] || die "Uninstall cancelled"

for component in ${selected_components}; do
  if [[ "${component}" == "php" && -z "${selected_php_versions}" ]]; then
    continue
  fi
  uninstall_component "${component}" "${selected_php_versions}"
  ok "$(uninstall_component_label "${component}") uninstall completed"
done

if report_uninstall_residuals "${selected_components}" "${selected_php_versions}"; then
  ok "All selected uninstall operations completed. Data, logs, sites, and certificates not explicitly selected were preserved."
else
  die "Uninstall operations ran, but program remnants remain; inspect the paths above"
fi
