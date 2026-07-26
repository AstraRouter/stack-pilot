#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/include/common.sh"
source "${PROJECT_ROOT}/include/install/options.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

ROOT_DIR="${tmp_dir}"
printf 'timezone=old\nuser=old\n' > "${ROOT_DIR}/options.conf"

option_keys=(
  timezone user group services_base_dir data_base_dir runtime_base_dir pid_dir sock_dir logs_dir
  nginx_ver mysql_ver mariadb_ver redis_ver
  nginx_install_dir php_install_base mysql_install_dir mariadb_install_dir redis_install_dir
  mysql_data_dir mariadb_data_dir redis_data_dir wwwroot_dir backup_dir
  nginx_log_dir php_log_dir mysql_log_dir mariadb_log_dir redis_log_dir
  mysql_sock mariadb_sock mysql_pid mariadb_pid nginx_pid
  mysql_password mariadb_password redis_password php_versions db_engine install_redis
  install_components install_memcached install_composer
  nginx_http_port nginx_https_port mysql_port mariadb_port redis_port redis_bind redis_appendonly
  memcached_install_dir composer_install_dir memcached_data_dir memcached_log_dir
  memcached_port memcached_bind memcached_memory
  php_pm php_pm_max_children php_pm_start_servers php_pm_min_spare_servers php_pm_max_spare_servers
  php_memory_limit php_upload_max_filesize php_post_max_size php_max_execution_time
  php_profile php_extensions php_pecl_extensions
  customize_service_ports manage_firewall open_database_port open_redis_port open_memcached_port
  php_security_hardening php_disable_functions
  nginx_worker_connections nginx_keepalive_timeout nginx_client_max_body_size
  nginx_security_headers nginx_hsts_max_age nginx_http3
  nginx_rate_limit nginx_rate_limit_rps nginx_rate_limit_burst nginx_conn_limit
  backup_keep_days upgrade_keep_failed
  manage_logrotate logrotate_interval logrotate_keep
  fail2ban_bantime fail2ban_findtime fail2ban_maxretry
)

for key in "${option_keys[@]}"; do
  printf -v "${key}" '%s-value' "${key}"
done
php_extensions="opcache mysqli"
php_pecl_extensions="redis memcached"
install_components="nginx php mysql"

save_runtime_options

assert_eq "timezone-value" "$(get_config_value "${ROOT_DIR}/options.conf" timezone)" "existing option should be updated"
assert_eq "user-value" "$(get_config_value "${ROOT_DIR}/options.conf" user)" "user option should be updated"
assert_eq "redis_password-value" "$(get_config_value "${ROOT_DIR}/options.conf" redis_password)" "password option should be written"
assert_eq "opcache mysqli" "$(get_config_value "${ROOT_DIR}/options.conf" php_extensions)" "space-separated PHP extensions should round-trip"
assert_eq "redis memcached" "$(get_config_value "${ROOT_DIR}/options.conf" php_pecl_extensions)" "space-separated PECL extensions should round-trip"
assert_eq "nginx php mysql" "$(get_config_value "${ROOT_DIR}/options.conf" install_components)" "space-separated components should round-trip"
assert_eq "php_disable_functions-value" "$(get_config_value "${ROOT_DIR}/options.conf" php_disable_functions)" "last option should be written"
assert_eq "nginx_ver-value" "$(get_config_value "${ROOT_DIR}/options.conf" nginx_ver)" "selected Nginx version should be written"
assert_eq "logrotate_keep-value" "$(get_config_value "${ROOT_DIR}/options.conf" logrotate_keep)" "log rotation options should round-trip"
assert_eq "nginx_client_max_body_size-value" \
  "$(get_config_value "${ROOT_DIR}/options.conf" nginx_client_max_body_size)" \
  "the request size limit should round-trip"

# An options.conf written by an older release does not define keys added since.
# Aborting on the unbound variable would lose the run at its very last step,
# after everything had already been installed.
missing_key_root="$(mktemp -d)"
(
  ROOT_DIR="${missing_key_root}"
  printf 'timezone=old\n' > "${ROOT_DIR}/options.conf"
  for key in "${option_keys[@]}"; do
    unset "${key}"
  done
  timezone="kept"
  save_runtime_options
) || fail "save_runtime_options must tolerate options that the file does not define"
assert_eq "kept" "$(get_config_value "${missing_key_root}/options.conf" timezone)" \
  "a defined option should still be written when others are missing"
assert_eq "" "$(get_config_value "${missing_key_root}/options.conf" logrotate_keep)" \
  "an undefined option should be written empty so its default applies at the point of use"
rm -rf "${missing_key_root}"

echo "PASS: install options"
