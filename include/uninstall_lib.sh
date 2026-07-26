#!/usr/bin/env bash

# Removal needs to know where the log-rotation and fail2ban files were written,
# so those modules are pulled in here rather than left to each caller.
# shellcheck source=/dev/null
source "${LNMP_ROOT_DIR}/include/logrotate.sh"
# shellcheck source=/dev/null
source "${LNMP_ROOT_DIR}/include/fail2ban.sh"

uninstall_unit_dir() {
  printf '%s' "${LNMP_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
}

uninstall_path_is_safe() {
  local path="${1%/}"
  [[ -n "${path}" && "${path}" == /* ]] || return 1
  [[ "${path}" != *'/../'* && "${path}" != */.. && "${path}" != *'/./'* ]] || return 1
  case "${path}" in
    /|/bin|/boot|/data|/dev|/etc|/home|/lib|/lib32|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var)
      return 1
      ;;
  esac
  ((${#path} >= 6))
}

uninstall_path_is_managed() {
  local path="${1%/}" root
  uninstall_path_is_safe "${path}" || return 1
  for root in \
    "${services_base_dir:-}" "${data_base_dir:-}" "${logs_dir:-}" \
    "${pid_dir:-}" "${sock_dir:-}"; do
    root="${root%/}"
    [[ -n "${root}" ]] || continue
    [[ "${path}" == "${root}/"* ]] && return 0
  done
  for root in "${wwwroot_dir:-}" "${backup_dir:-}" "${LNMP_SRC_DIR:-}"; do
    root="${root%/}"
    [[ -n "${root}" ]] || continue
    [[ "${path}" == "${root}" || "${path}" == "${root}/"* ]] && return 0
  done
  case "${path}" in
    /etc/letsencrypt|/var/lib/letsencrypt|/var/log/letsencrypt) return 0 ;;
  esac
  return 1
}

safe_remove_managed_path() {
  local path="$1"
  [[ -e "${path}" || -L "${path}" ]] || return 0
  uninstall_path_is_managed "${path}" || die "Refusing to remove an unmanaged or unsafe path: ${path}"
  rm -rf -- "${path}"
}

safe_remove_managed_file() {
  local path="$1"
  [[ -e "${path}" || -L "${path}" ]] || return 0
  uninstall_path_is_managed "${path}" || die "Refusing to remove an unmanaged file: ${path}"
  rm -f -- "${path}"
}

remove_managed_symlink() {
  local link="$1" expected_prefix="${2%/}" target
  # An empty prefix would turn the "${expected_prefix}/"* pattern below into
  # /* and match every absolute symlink target.
  [[ -n "${expected_prefix}" ]] || return 0
  [[ -L "${link}" ]] || return 0
  target="$(readlink "${link}" 2>/dev/null || true)"
  case "${target}" in
    "${expected_prefix}"|"${expected_prefix}/"*) rm -f -- "${link}" ;;
  esac
}

stop_disable_remove_service() {
  local service="$1" unit_name unit
  case "${service}" in *.service|*.timer) unit_name="${service}" ;; *) unit_name="${service}.service" ;; esac
  unit="$(uninstall_unit_dir)/${unit_name}"
  if [[ "${LNMP_UNINSTALL_SKIP_SERVICE_ACTIONS:-0}" != "1" ]] && command_exists systemctl; then
    systemctl stop "${unit_name}" >/dev/null 2>&1 || true
    systemctl disable "${unit_name}" >/dev/null 2>&1 || true
  fi
  rm -f -- "${unit}"
  if [[ "${LNMP_UNINSTALL_SKIP_SERVICE_ACTIONS:-0}" != "1" ]] && command_exists systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

clear_component_state_markers() {
  local prefix="$1" marker
  [[ -d "${LNMP_STATE_DIR}" ]] || return 0
  for marker in "${LNMP_STATE_DIR}/${prefix}"*.done; do
    [[ -f "${marker}" ]] && rm -f -- "${marker}"
  done
  return 0
}

remove_source_cache_url() {
  local url="${1:-}" output="${2:-}"
  [[ "${UNINSTALL_REMOVE_SOURCES:-n}" == "y" && -n "${url}" ]] || return 0
  [[ -n "${output}" ]] || output="${url##*/}"
  safe_remove_managed_file "${LNMP_SRC_DIR}/${output}"
  safe_remove_managed_file "${LNMP_SRC_DIR}/${output}.part"
}

remove_component_log_dir() {
  [[ "${UNINSTALL_REMOVE_LOGS:-n}" == "y" ]] || return 0
  safe_remove_managed_path "$1"
}

remove_component_data_dir() {
  [[ "${UNINSTALL_REMOVE_DATA:-n}" == "y" ]] || return 0
  safe_remove_managed_path "$1"
}

remove_component_runtime_file() {
  safe_remove_managed_file "$1"
}

uninstall_nginx() {
  stop_disable_remove_service nginx
  remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/nginx" "${nginx_install_dir}"
  safe_remove_managed_path "${nginx_install_dir}"
  remove_component_log_dir "${nginx_log_dir}"
  remove_component_runtime_file "${nginx_pid}"
  if [[ "${UNINSTALL_REMOVE_WWW:-n}" == "y" ]]; then safe_remove_managed_path "${wwwroot_dir}"; fi
  remove_source_cache_url "${nginx_url:-}"
  clear_component_state_markers "$(safe_state_name "nginx:")"
}

uninstall_php_versions() {
  local versions="$1" version dir bin remaining first
  for version in ${versions}; do
    stop_disable_remove_service "$(php_service_name "${version}")"
    dir="$(php_install_dir_for_version "${version}")"
    for bin in php phpize php-config pecl pear; do
      remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/${bin}" "${dir}"
    done
    safe_remove_managed_path "${dir}"
    remove_source_cache_url "$(php_source_url "${version}" 2>/dev/null || true)"
    clear_component_state_markers "$(safe_state_name "php:${version}")"
  done

  remaining="$(installed_php_versions 2>/dev/null || true)"
  if [[ -n "${remaining}" ]]; then
    first="${remaining%% *}"
    switch_cli_php_version "${first}"
  else
    for bin in php phpize php-config pecl pear; do
      remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/${bin}" "${php_install_base}"
    done
    remove_component_log_dir "${php_log_dir}"
    clear_component_state_markers php_
  fi
}

remove_database_cli_links() {
  local install_dir="$1" bin
  for bin in mysql mysqladmin mysqldump mysqlshow mariadb mariadb-admin mariadb-dump; do
    remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/${bin}" "${install_dir}"
  done
}

remove_my_cnf_if_unused() {
  [[ -e /etc/my.cnf ]] || return 0
  [[ -d "${mysql_install_dir}" || -d "${mariadb_install_dir}" ]] && return 0
  [[ "${LNMP_UNINSTALL_SKIP_SYSTEM_CONFIG:-0}" == "1" ]] && return 0
  # An empty install dir would degrade the pattern to the substring "basedir="
  # and match a my.cnf belonging to an unrelated database installation.
  if { [[ -n "${mysql_install_dir:-}" ]] && grep -Fq "basedir=${mysql_install_dir}" /etc/my.cnf 2>/dev/null; } || \
     { [[ -n "${mariadb_install_dir:-}" ]] && grep -Fq "basedir=${mariadb_install_dir}" /etc/my.cnf 2>/dev/null; }; then
    rm -f -- /etc/my.cnf
  else
    warn "/etc/my.cnf was not generated for the current Stack Pilot paths and was preserved"
  fi
}

uninstall_mysql() {
  stop_disable_remove_service mysqld
  remove_database_cli_links "${mysql_install_dir}"
  safe_remove_managed_path "${mysql_install_dir}"
  remove_component_data_dir "${mysql_data_dir}"
  remove_component_log_dir "${mysql_log_dir}"
  remove_component_runtime_file "${mysql_pid}"
  remove_component_runtime_file "${mysql_sock}"
  remove_source_cache_url "$(mysql_binary_url 2>/dev/null || true)"
  clear_component_state_markers mysql_
  remove_my_cnf_if_unused
}

uninstall_mariadb() {
  stop_disable_remove_service mariadb
  remove_database_cli_links "${mariadb_install_dir}"
  safe_remove_managed_path "${mariadb_install_dir}"
  remove_component_data_dir "${mariadb_data_dir}"
  remove_component_log_dir "${mariadb_log_dir}"
  remove_component_runtime_file "${mariadb_pid}"
  remove_component_runtime_file "${mariadb_sock}"
  remove_source_cache_url "$(mariadb_binary_url 2>/dev/null || true)"
  clear_component_state_markers mariadb_
  remove_my_cnf_if_unused
}

uninstall_redis() {
  stop_disable_remove_service redis-server
  remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/redis-cli" "${redis_install_dir}"
  remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/redis-server" "${redis_install_dir}"
  safe_remove_managed_path "${redis_install_dir}"
  remove_component_data_dir "${redis_data_dir}"
  remove_component_log_dir "${redis_log_dir}"
  remove_component_runtime_file "${pid_dir}/redis.pid"
  remove_source_cache_url "${redis_url:-}"
  clear_component_state_markers redis_
}

uninstall_memcached() {
  stop_disable_remove_service memcached
  remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/memcached" "${memcached_install_dir}"
  safe_remove_managed_path "${memcached_install_dir}"
  remove_component_data_dir "${memcached_data_dir}"
  remove_component_log_dir "${memcached_log_dir}"
  remove_component_runtime_file "${pid_dir}/memcached.pid"
  clear_component_state_markers memcached
}

remove_certbot_renew_job() {
  stop_disable_remove_service lnmp-certbot-renew.timer
  stop_disable_remove_service lnmp-certbot-renew
  if [[ "${LNMP_UNINSTALL_SKIP_SERVICE_ACTIONS:-0}" != "1" ]] && command_exists crontab; then
    local existing current
    existing="$(crontab -l 2>/dev/null || true)"
    # Only touch the crontab when one exists, so uninstalling never creates an
    # empty crontab for an account that had none.
    if [[ -n "${existing}" ]]; then
      current="$(printf '%s\n' "${existing}" | grep -v "${LNMP_CERTBOT_CRON_MARKER:-# stack-pilot-certbot-renew}" || true)"
      printf '%s\n' "${current}" | crontab - 2>/dev/null || true
    fi
  fi
}

uninstall_certbot() {
  remove_certbot_renew_job
  if [[ "${LNMP_UNINSTALL_SKIP_PACKAGE_ACTIONS:-0}" != "1" ]]; then
    if command_exists snap && snap list certbot >/dev/null 2>&1; then
      snap remove certbot
      [[ -L /usr/bin/certbot && "$(readlink /usr/bin/certbot)" == /snap/bin/certbot ]] && rm -f /usr/bin/certbot
    elif command_exists certbot; then
      detect_os
      case "${PM}" in
        apt-get) wait_for_apt_locks; run_apt_get remove -y certbot ;;
        dnf|yum) "${PM}" remove -y certbot ;;
        zypper) run_zypper remove certbot ;;
      esac
    fi
  fi
  if [[ "${UNINSTALL_REMOVE_CERTIFICATES:-n}" == "y" ]]; then
    safe_remove_managed_path /etc/letsencrypt
    safe_remove_managed_path /var/lib/letsencrypt
    safe_remove_managed_path /var/log/letsencrypt
  fi
  clear_component_state_markers certbot
}

uninstall_composer() {
  remove_managed_symlink "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/composer" "${composer_install_dir}"
  safe_remove_managed_path "${composer_install_dir}"
  # The installer is no longer cached, but a copy left by an earlier release
  # would keep failing its signature check, so it is cleaned up here.
  remove_source_cache_url "https://getcomposer.org/installer" composer-setup.php
  clear_component_state_markers composer
}

# Only the jail file this installer wrote is removed. fail2ban itself and any
# jails the administrator added stay, because they may be protecting services
# that have nothing to do with this stack.
uninstall_fail2ban() {
  local jail
  jail="$(fail2ban_jail_path)"
  [[ -f "${jail}" ]] && rm -f -- "${jail}"
  if [[ "${LNMP_UNINSTALL_SKIP_SERVICE_ACTIONS:-0}" != "1" ]] && command_exists systemctl; then
    systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
  fi
  clear_component_state_markers fail2ban
  return 0
}

# Rotation covers several components at once, so it is removed when the last of
# them goes rather than alongside any single one.
remove_logrotate_config_if_unused() {
  local config
  config="$(logrotate_config_path)"
  [[ -f "${config}" ]] || return 0
  [[ -d "${nginx_install_dir:-}" ]] && return 0
  [[ -d "${php_install_base:-}" ]] && return 0
  [[ -d "${mysql_install_dir:-}" || -d "${mariadb_install_dir:-}" ]] && return 0
  [[ -d "${redis_install_dir:-}" || -d "${memcached_install_dir:-}" ]] && return 0
  rm -f -- "${config}"
  return 0
}

uninstall_component() {
  local component="$1" php_versions_to_remove="${2:-}"
  case "${component}" in
    nginx) uninstall_nginx ;;
    php) uninstall_php_versions "${php_versions_to_remove}" ;;
    mysql) uninstall_mysql ;;
    mariadb) uninstall_mariadb ;;
    redis) uninstall_redis ;;
    memcached) uninstall_memcached ;;
    certbot) uninstall_certbot ;;
    composer) uninstall_composer ;;
    fail2ban) uninstall_fail2ban ;;
    *) die "Unknown component to uninstall: ${component}" ;;
  esac
  remove_logrotate_config_if_unused
}

uninstall_component_label() {
  case "$1" in
    nginx) printf 'Nginx' ;; php) printf 'PHP' ;; mysql) printf 'MySQL' ;;
    mariadb) printf 'MariaDB' ;; redis) printf 'Redis' ;; memcached) printf 'Memcached' ;;
    certbot) printf 'Certbot' ;; composer) printf 'Composer' ;; fail2ban) printf 'fail2ban' ;;
    *) printf '%s' "$1" ;;
  esac
}

uninstall_report_path_if_present() {
  local label="$1" path="$2"
  [[ -e "${path}" || -L "${path}" ]] || return 0
  warn "A ${label} remains after uninstall: ${path}"
  UNINSTALL_RESIDUAL_COUNT=$((UNINSTALL_RESIDUAL_COUNT + 1))
}

uninstall_report_managed_link_if_present() {
  local link="$1" expected_prefix="${2%/}" target
  [[ -L "${link}" ]] || return 0
  target="$(readlink "${link}" 2>/dev/null || true)"
  case "${target}" in
    "${expected_prefix}"|"${expected_prefix}/"*)
      uninstall_report_path_if_present "command link" "${link}"
      ;;
  esac
}

report_uninstall_residuals() {
  local components="$1" php_versions_to_check="${2:-}" component version bin unit_dir
  unit_dir="$(uninstall_unit_dir)"
  UNINSTALL_RESIDUAL_COUNT=0

  for component in ${components}; do
    case "${component}" in
      nginx)
        uninstall_report_path_if_present "program directory" "${nginx_install_dir}"
        uninstall_report_path_if_present "service unit" "${unit_dir}/nginx.service"
        uninstall_report_managed_link_if_present "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/nginx" "${nginx_install_dir}"
        ;;
      php)
        for version in ${php_versions_to_check}; do
          uninstall_report_path_if_present "program directory" "$(php_install_dir_for_version "${version}")"
          uninstall_report_path_if_present "service unit" "${unit_dir}/$(php_service_name "${version}").service"
        done
        ;;
      mysql)
        uninstall_report_path_if_present "program directory" "${mysql_install_dir}"
        uninstall_report_path_if_present "service unit" "${unit_dir}/mysqld.service"
        for bin in mysql mysqladmin mysqldump mysqlshow; do
          uninstall_report_managed_link_if_present "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/${bin}" "${mysql_install_dir}"
        done
        ;;
      mariadb)
        uninstall_report_path_if_present "program directory" "${mariadb_install_dir}"
        uninstall_report_path_if_present "service unit" "${unit_dir}/mariadb.service"
        for bin in mariadb mariadb-admin mariadb-dump; do
          uninstall_report_managed_link_if_present "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/${bin}" "${mariadb_install_dir}"
        done
        ;;
      redis)
        uninstall_report_path_if_present "program directory" "${redis_install_dir}"
        uninstall_report_path_if_present "service unit" "${unit_dir}/redis-server.service"
        for bin in redis-cli redis-server; do
          uninstall_report_managed_link_if_present "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/${bin}" "${redis_install_dir}"
        done
        ;;
      memcached)
        uninstall_report_path_if_present "program directory" "${memcached_install_dir}"
        uninstall_report_path_if_present "service unit" "${unit_dir}/memcached.service"
        uninstall_report_managed_link_if_present "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/memcached" "${memcached_install_dir}"
        ;;
      certbot)
        uninstall_report_path_if_present "renewal timer" "${unit_dir}/lnmp-certbot-renew.timer"
        uninstall_report_path_if_present "renewal service" "${unit_dir}/lnmp-certbot-renew.service"
        ;;
      composer)
        uninstall_report_path_if_present "program directory" "${composer_install_dir}"
        uninstall_report_managed_link_if_present "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/composer" "${composer_install_dir}"
        ;;
      fail2ban)
        uninstall_report_path_if_present "jail configuration" "$(fail2ban_jail_path)"
        ;;
    esac
  done

  if ((UNINSTALL_RESIDUAL_COUNT == 0)); then
    ok "No managed program residuals remain after uninstall"
    return 0
  fi
  warn "Found ${UNINSTALL_RESIDUAL_COUNT} managed program residual(s); preserved data, logs, websites, and certificates are not counted"
  return 1
}
