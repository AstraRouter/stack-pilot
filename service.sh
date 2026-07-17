#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_options
source "${ROOT_DIR}/include/php.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./service.sh"
    echo "Run without parameters and follow the menu."
    exit 0
    ;;
  "") ;;
  *) warn "service.sh does not accept operation arguments; opening the interactive menu." ;;
esac

service_action() {
  local service="$1"
  local action="$2"
  require_root
  if command_exists systemctl; then
    systemctl "${action}" "${service}"
  else
    service "${service}" "${action}"
  fi
}

choose_php_version_for_cli() {
  local installed configured available default entries version
  installed="$(installed_php_versions)"
  configured="$(normalize_php_versions "${php_versions}" 2>/dev/null || true)"
  available="${installed:-${configured}}"
  default="${available%% *}"
  [[ -n "${default}" ]] || default="84"
  entries=()
  for version in ${available:-54 55 56 70 71 72 73 74 80 81 82 83 84 85}; do
    entries+=("${version}|PHP $(php_version_label "${version}")")
  done
  prompt_select "Select the default CLI PHP version" "${default}" "${entries[@]}"
}

while :; do
  print_header
  svc="$(prompt_select "Select a service" "nginx" \
    "nginx|Nginx" \
    "mysqld|MySQL" \
    "mariadb|MariaDB" \
    "redis-server|Redis" \
    "memcached|Memcached" \
    "php84-fpm|PHP 8.4 FPM" \
    "switch-cli-php|Switch the default CLI PHP version" \
    "custom|Enter a service name manually" \
    "exit|Exit")"
  [[ "${svc}" == "exit" ]] && exit 0
  if [[ "${svc}" == "switch-cli-php" ]]; then
    require_root
    php_ver="$(choose_php_version_for_cli)"
    switch_cli_php_version "${php_ver}"
    echo
    read -r -p "Press Enter to return to the menu..." _
    continue
  fi
  [[ "${svc}" == "custom" ]] && svc="$(prompt_input "Enter the service name" "")"
  action="$(prompt_select "Select an action" "status" \
    "status|Show status" \
    "start|Start" \
    "stop|Stop" \
    "restart|Restart" \
    "reload|Reload")"
  service_action "${svc}" "${action}"
  echo
  read -r -p "Press Enter to return to the menu..." _
done
