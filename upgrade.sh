#!/usr/bin/env bash
set -euo pipefail

# The pre-upgrade backup archives options.conf and install.txt, and component
# snapshots archive redis.conf, so every artifact this tool writes contains
# plaintext credentials. Keep them private (new files 0600, directories 0700).
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
load_options
source "${ROOT_DIR}/include/nginx.sh"
source "${ROOT_DIR}/include/php_extensions.sh"
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/redis.sh"
source "${ROOT_DIR}/include/composer.sh"
source "${ROOT_DIR}/include/upgrade_lib.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./upgrade.sh"
    echo "Run without parameters and follow the menu."
    exit 0
    ;;
  "") ;;
  *) warn "upgrade.sh does not accept operation arguments; opening the interactive menu." ;;
esac

upgrade_composer_self() {
  if [[ -x "${composer_install_dir}/composer" ]]; then
    "${composer_install_dir}/composer" self-update
  elif command_exists composer; then
    composer self-update
  else
    warn "Composer was not found"
  fi
}

while :; do
  print_header
  choice="$(prompt_select "Select a component to upgrade" "1" \
    "1|Nginx (reinstall the version selected in versions.conf)" \
    "2|Redis (reinstall the version selected in versions.conf)" \
    "3|A specific PHP version (reinstall from versions.conf)" \
    "4|Composer self-update" \
    "5|Exit")"
  case "${choice}" in
    1)
      require_root
      backup_before_upgrade "${nginx_install_dir}/conf"
      transactional_component_upgrade Nginx "nginx:${nginx_ver}" "${nginx_install_dir}" nginx \
        nginx_upgrade_health preserve_nginx_upgrade_config install_nginx
      ;;
    2)
      require_root
      backup_before_upgrade "${redis_install_dir}/etc"
      transactional_component_upgrade Redis "redis:${redis_ver}" "${redis_install_dir}" redis-server \
        redis_upgrade_health preserve_redis_upgrade_config install_redis_server
      ;;
    3)
      require_root
      php_ver="$(prompt_input "Enter a short PHP version, for example 84" "84")"
      php_ver="$(normalize_php_versions "${php_ver}")" || die "Unsupported PHP version"
      [[ "${php_ver}" != *" "* ]] || die "Only one PHP version can be upgraded at a time"
      backup_before_upgrade "$(php_install_dir_for_version "${php_ver}")/etc"
      UPGRADE_PHP_SHORT="${php_ver}"
      transactional_component_upgrade "PHP-${php_ver}" "php:${php_ver}" "$(php_install_dir_for_version "${php_ver}")" \
        "$(php_service_name "${php_ver}")" php_upgrade_health preserve_php_upgrade_config install_php_version "${php_ver}"
      ;;
    4) require_root; upgrade_composer_self ;;
    5) exit 0 ;;
  esac
  ok "Upgrade operation completed"
done
