#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
load_options
source "${ROOT_DIR}/include/php_extensions.sh"
source "${ROOT_DIR}/include/php.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./addons.sh"
    echo "Run without parameters and follow the menu."
    exit 0
    ;;
  "") ;;
  *) warn "addons.sh does not accept operation arguments; opening the interactive menu." ;;
esac

choose_php_version_for_addons() {
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
  prompt_select "Select a PHP version" "${default}" "${entries[@]}"
}

select_pecl_extensions() {
  local entries entry
  entries=()
  while IFS= read -r entry; do
    entries+=("${entry}")
  done < <(php_pecl_entries_args)
  prompt_multi_select "Select PHP extensions to install" "${php_pecl_extensions:-redis memcached imagick}" "${entries[@]}"
}

while :; do
  print_header
  choice="$(prompt_select "Select an action" "1" \
    "1|Install PHP PECL/additional extensions" \
    "2|List extensions" \
    "3|Exit")"
  case "${choice}" in
    1)
      require_root
      php_ver="$(choose_php_version_for_addons)"
      extensions="$(select_pecl_extensions)"
      install_php_pecl_extensions "${php_ver}" "${extensions}"
      ;;
    2)
      php_builtin_extension_entries
      php_pecl_extension_entries
      ;;
    3)
      exit 0
      ;;
  esac
  echo
  read -r -p "Press Enter to return to the menu..." _
done
