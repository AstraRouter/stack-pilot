#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/uninstall_lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_missing() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "path should be removed: $1"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

services_base_dir="${tmp_dir}/services"
data_base_dir="${tmp_dir}/data"
runtime_base_dir="${tmp_dir}/runtime"
logs_dir="${tmp_dir}/logs"
pid_dir="${runtime_base_dir}/pid"
sock_dir="${runtime_base_dir}/sock"
wwwroot_dir="${tmp_dir}/www"
backup_dir="${tmp_dir}/backup"
LNMP_SRC_DIR="${tmp_dir}/src"
LNMP_STATE_DIR="${tmp_dir}/state"
LNMP_CLI_BIN_DIR="${tmp_dir}/bin"
LNMP_SYSTEMD_UNIT_DIR="${tmp_dir}/systemd"
LNMP_UNINSTALL_SKIP_SERVICE_ACTIONS=1
LNMP_UNINSTALL_SKIP_PACKAGE_ACTIONS=1
LNMP_UNINSTALL_SKIP_SYSTEM_CONFIG=1
UNINSTALL_REMOVE_DATA=n
UNINSTALL_REMOVE_WWW=n
UNINSTALL_REMOVE_LOGS=n
UNINSTALL_REMOVE_CERTIFICATES=n
UNINSTALL_REMOVE_SOURCES=n
mkdir -p "${services_base_dir}" "${data_base_dir}" "${logs_dir}" "${pid_dir}" "${sock_dir}" \
  "${wwwroot_dir}" "${backup_dir}" "${LNMP_SRC_DIR}" "${LNMP_STATE_DIR}" \
  "${LNMP_CLI_BIN_DIR}" "${LNMP_SYSTEMD_UNIT_DIR}"

uninstall_path_is_safe "${services_base_dir}/nginx" || fail "managed component path should be safe"
if uninstall_path_is_managed "${services_base_dir}"; then fail "shared services root must not be removable"; fi
if uninstall_path_is_managed "${data_base_dir}"; then fail "shared data root must not be removable"; fi
if uninstall_path_is_managed "${logs_dir}"; then fail "shared logs root must not be removable"; fi
if uninstall_path_is_safe /; then fail "filesystem root must be rejected"; fi
if uninstall_path_is_safe /usr/local; then fail "shared install root must be rejected"; fi
if uninstall_path_is_managed /etc/passwd; then fail "unmanaged system file must be rejected"; fi
if (safe_remove_managed_path / >/dev/null 2>&1); then fail "safe remove must reject root"; fi

nginx_install_dir="${services_base_dir}/nginx"
nginx_log_dir="${logs_dir}/nginx"
nginx_pid="${pid_dir}/nginx.pid"
mkdir -p "${nginx_install_dir}/sbin" "${nginx_log_dir}"
printf '#!/bin/sh\n' > "${nginx_install_dir}/sbin/nginx"
printf 'log\n' > "${nginx_log_dir}/error.log"
printf 'pid\n' > "${nginx_pid}"
printf 'unit\n' > "${LNMP_SYSTEMD_UNIT_DIR}/nginx.service"
printf 'state\n' > "${LNMP_STATE_DIR}/nginx_1.28.1.done"
ln -s "${nginx_install_dir}/sbin/nginx" "${LNMP_CLI_BIN_DIR}/nginx"
printf 'site\n' > "${wwwroot_dir}/index.html"
uninstall_nginx
assert_missing "${nginx_install_dir}"
assert_missing "${nginx_pid}"
assert_missing "${LNMP_SYSTEMD_UNIT_DIR}/nginx.service"
assert_missing "${LNMP_CLI_BIN_DIR}/nginx"
assert_missing "${LNMP_STATE_DIR}/nginx_1.28.1.done"
[[ -f "${nginx_log_dir}/error.log" ]] || fail "logs should be preserved by default"
[[ -f "${wwwroot_dir}/index.html" ]] || fail "website should be preserved by default"

php_install_base="${services_base_dir}/php"
php_log_dir="${logs_dir}/php"
for version in 84 85; do
  mkdir -p "${php_install_base}/${version}/sbin" "${php_install_base}/${version}/bin"
  printf '#!/bin/sh\n' > "${php_install_base}/${version}/sbin/php-fpm"
  chmod +x "${php_install_base}/${version}/sbin/php-fpm"
  for bin in php phpize php-config pecl pear; do
    printf '#!/bin/sh\n' > "${php_install_base}/${version}/bin/${bin}"
    chmod +x "${php_install_base}/${version}/bin/${bin}"
  done
  printf 'unit\n' > "${LNMP_SYSTEMD_UNIT_DIR}/php${version}-fpm.service"
  printf 'state\n' > "${LNMP_STATE_DIR}/php_${version}.done"
done
for bin in php phpize php-config pecl pear; do
  ln -s "${php_install_base}/84/bin/${bin}" "${LNMP_CLI_BIN_DIR}/${bin}"
done
uninstall_php_versions 84
assert_missing "${php_install_base}/84"
[[ -x "${php_install_base}/85/sbin/php-fpm" ]] || fail "unselected PHP version should remain"
[[ "$(readlink "${LNMP_CLI_BIN_DIR}/php")" == "${php_install_base}/85/bin/php" ]] || fail "CLI PHP should switch to remaining version"

mysql_install_dir="${services_base_dir}/mysql"
mariadb_install_dir="${services_base_dir}/mariadb"
mysql_data_dir="${data_base_dir}/mysql"
mariadb_data_dir="${data_base_dir}/mariadb"
mysql_log_dir="${logs_dir}/mysql"
mysql_pid="${pid_dir}/mysql.pid"
mysql_sock="${sock_dir}/mysql.sock"
mkdir -p "${mysql_install_dir}/bin" "${mysql_data_dir}" "${mysql_log_dir}"
printf '#!/bin/sh\n' > "${mysql_install_dir}/bin/mysql"
printf 'data\n' > "${mysql_data_dir}/important.db"
printf 'log\n' > "${mysql_log_dir}/error.log"
printf 'pid\n' > "${mysql_pid}"
printf 'socket\n' > "${mysql_sock}"
printf 'unit\n' > "${LNMP_SYSTEMD_UNIT_DIR}/mysqld.service"
printf 'state\n' > "${LNMP_STATE_DIR}/mysql_8.4.0.done"
ln -s "${mysql_install_dir}/bin/mysql" "${LNMP_CLI_BIN_DIR}/mysql"
uninstall_mysql
assert_missing "${mysql_install_dir}"
assert_missing "${mysql_pid}"
assert_missing "${mysql_sock}"
assert_missing "${LNMP_CLI_BIN_DIR}/mysql"
[[ -f "${mysql_data_dir}/important.db" ]] || fail "database data should be preserved by default"
[[ -f "${mysql_log_dir}/error.log" ]] || fail "database log should be preserved by default"

UNINSTALL_REMOVE_DATA=y
remove_component_data_dir "${mysql_data_dir}"
assert_missing "${mysql_data_dir}"
UNINSTALL_REMOVE_LOGS=y
remove_component_log_dir "${mysql_log_dir}"
assert_missing "${mysql_log_dir}"
UNINSTALL_REMOVE_DATA=n
UNINSTALL_REMOVE_LOGS=n

mariadb_log_dir="${logs_dir}/mariadb"
mariadb_pid="${pid_dir}/mariadb.pid"
mariadb_sock="${sock_dir}/mariadb.sock"
redis_install_dir="${services_base_dir}/redis"
redis_data_dir="${data_base_dir}/redis"
redis_log_dir="${logs_dir}/redis"
memcached_install_dir="${services_base_dir}/memcached"
memcached_data_dir="${data_base_dir}/memcached"
memcached_log_dir="${logs_dir}/memcached"
composer_install_dir="${services_base_dir}/composer"
mkdir -p "${mariadb_install_dir}/bin" "${mariadb_data_dir}" "${mariadb_log_dir}" \
  "${redis_install_dir}/bin" "${redis_data_dir}" "${redis_log_dir}" \
  "${memcached_install_dir}/bin" "${memcached_data_dir}" "${memcached_log_dir}" \
  "${composer_install_dir}"
for unit in mariadb redis-server memcached; do
  printf 'unit\n' > "${LNMP_SYSTEMD_UNIT_DIR}/${unit}.service"
done
printf '#!/bin/sh\n' > "${mariadb_install_dir}/bin/mariadb"
printf '#!/bin/sh\n' > "${redis_install_dir}/bin/redis-cli"
printf '#!/bin/sh\n' > "${memcached_install_dir}/bin/memcached"
printf '#!/bin/sh\n' > "${composer_install_dir}/composer"
ln -s "${mariadb_install_dir}/bin/mariadb" "${LNMP_CLI_BIN_DIR}/mariadb"
ln -s "${redis_install_dir}/bin/redis-cli" "${LNMP_CLI_BIN_DIR}/redis-cli"
ln -s "${memcached_install_dir}/bin/memcached" "${LNMP_CLI_BIN_DIR}/memcached"
ln -s "${composer_install_dir}/composer" "${LNMP_CLI_BIN_DIR}/composer"
for component in mariadb redis memcached composer; do
  uninstall_component "${component}"
done
uninstall_php_versions 85
for path in "${mariadb_install_dir}" "${redis_install_dir}" "${memcached_install_dir}" "${composer_install_dir}" "${php_install_base}/85"; do
  assert_missing "${path}"
done
[[ -d "${mariadb_data_dir}" && -d "${redis_data_dir}" && -d "${memcached_data_dir}" ]] || \
  fail "all component program removal must preserve data by default"

printf 'timer\n' > "${LNMP_SYSTEMD_UNIT_DIR}/lnmp-certbot-renew.timer"
printf 'service\n' > "${LNMP_SYSTEMD_UNIT_DIR}/lnmp-certbot-renew.service"
remove_certbot_renew_job
assert_missing "${LNMP_SYSTEMD_UNIT_DIR}/lnmp-certbot-renew.timer"
assert_missing "${LNMP_SYSTEMD_UNIT_DIR}/lnmp-certbot-renew.service"

report_uninstall_residuals "nginx php mysql mariadb redis memcached certbot composer" "84 85" >/dev/null || \
  fail "all removed components must pass residual scan"
mkdir -p "${nginx_install_dir}"
if report_uninstall_residuals "nginx" "" >/dev/null 2>&1; then
  fail "residual scan must fail when a managed program directory remains"
fi
safe_remove_managed_path "${nginx_install_dir}"

echo "PASS: uninstall safety and selective removal"
