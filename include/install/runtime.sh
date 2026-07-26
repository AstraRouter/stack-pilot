#!/usr/bin/env bash

prepare_selected_component_layout() {
  init_layout_dirs
  mkdir -p "${wwwroot_dir}" "${LNMP_SRC_DIR}"

  if has_component nginx; then
    mkdir -p "${nginx_log_dir}" "${wwwroot_dir}/default"
    touch "${nginx_log_dir}/access.log" "${nginx_log_dir}/error.log"
  fi

  if has_component php; then
    mkdir -p "${php_log_dir}"
    chown "${user}:${group}" "${php_log_dir}" 2>/dev/null || true
    local version
    for version in ${php_versions}; do
      prepare_service_log_file "${php_log_dir}/php${version}-fpm.log" "${user}" "${group}"
    done
  fi

  if has_component mysql && [[ "${db_engine}" == "mysql" ]]; then
    ensure_user_group mysql mysql
    mkdir -p "${mysql_data_dir}" "$(dirname "${mysql_install_dir}")"
    prepare_service_log_file "${mysql_log_dir}/error.log" mysql mysql
    prepare_service_log_file "${mysql_log_dir}/password-reset.log" mysql mysql
    chown mysql:mysql "${mysql_data_dir}" 2>/dev/null || true
  fi

  if has_component mariadb && [[ "${db_engine}" == "mariadb" ]]; then
    ensure_user_group mysql mysql
    mkdir -p "${mariadb_data_dir}" "$(dirname "${mariadb_install_dir}")"
    prepare_service_log_file "${mariadb_log_dir}/error.log" mysql mysql
    prepare_service_log_file "${mariadb_log_dir}/password-reset.log" mysql mysql
    chown mysql:mysql "${mariadb_data_dir}" 2>/dev/null || true
  fi

  if has_component redis; then
    ensure_user_group redis redis
    mkdir -p "${redis_data_dir}"
    prepare_service_log_file "${redis_log_dir}/redis.log" redis redis
    chown redis:redis "${redis_data_dir}" 2>/dev/null || true
  fi

  if has_component memcached; then
    ensure_user_group memcached memcached
    mkdir -p "${memcached_data_dir:-/usr/local/data/memcached}" "${memcached_log_dir:-/data/logs/memcached}"
    chown memcached:memcached "${memcached_data_dir:-/usr/local/data/memcached}" "${memcached_log_dir:-/data/logs/memcached}" 2>/dev/null || true
  fi
}

# Exporting TZ only affects this process. Cron jobs, service log timestamps, and
# database sessions all follow the system zone, so it is set too when the host
# provides timedatectl and knows the zone.
apply_system_timezone() {
  local zone="${timezone:-}"
  [[ -n "${zone}" ]] || return 0
  validate_timezone "${zone}" || die "Invalid timezone: ${zone}"
  export TZ="${zone}"
  [[ "${LNMP_SET_SYSTEM_TIMEZONE:-y}" == "y" ]] || return 0
  command_exists timedatectl || return 0
  if [[ ! -e "/usr/share/zoneinfo/${zone}" ]]; then
    warn "Time zone ${zone} is not in this system's zoneinfo database; the system clock zone was left unchanged"
    return 0
  fi
  timedatectl set-timezone "${zone}" >/dev/null 2>&1 ||
    warn "Could not set the system time zone; set it manually with: timedatectl set-timezone ${zone}"
}

run_install() {
  require_root
  validate_unix_username "${user}" || die "Invalid service user: ${user}"
  validate_unix_username "${group}" || die "Invalid service group: ${group}"
  apply_system_timezone
  ensure_user_group "${user}" "${group}"
  prepare_selected_component_layout
  preflight_system_dependencies
  install_build_dependencies

  if has_component nginx; then
    run_step_once "nginx:${nginx_ver}" install_nginx
  fi
  case "${db_engine}" in
    mysql) has_component mysql && run_step_once "mysql:${mysql_ver}" install_mysql ;;
    mariadb) has_component mariadb && run_step_once "mariadb:${mariadb_ver}" install_mariadb ;;
    none) ;;
  esac
  # Persist the (possibly generated) DB password immediately so a later failure can't lose it.
  case "${db_engine}" in
    mysql|mariadb) save_runtime_options; save_install_summary ;;
  esac
  if has_component php; then
    install_php_versions "${php_versions}"
  fi
  if has_component redis; then
    run_step_once "redis:${redis_ver}" install_redis_server
  fi
  if has_component memcached; then
    run_step_once memcached install_memcached_server
  fi
  if has_component composer; then
    run_step_once composer install_composer
  fi
  if has_component certbot; then
    run_step_once certbot install_certbot || warn "Certbot could not be installed automatically; retry from vhost.sh or install it manually"
  fi
  if has_component fail2ban; then
    run_step_once fail2ban install_fail2ban || warn "fail2ban was not configured; install it manually to enable brute-force protection"
  fi
  apply_php_security || true
  configure_logrotate || true
  configure_firewall || true
  save_runtime_options
  save_install_summary
}

# Rough free space needed under LNMP_SRC_DIR, in MB. Archives, extracted trees,
# and object files all land there, and each PHP version is built separately.
estimated_required_space_mb() {
  local total=512 version php_count=0
  if has_component php; then
    for version in ${php_versions:-}; do
      php_count=$((php_count + 1))
    done
    ((php_count > 0)) || php_count=1
    total=$((total + php_count * 2048))
  fi
  case "${db_engine:-none}" in mysql|mariadb) total=$((total + 4096)) ;; esac
  has_component nginx && total=$((total + 256))
  has_component redis && total=$((total + 256))
  printf '%s' "${total}"
}

# Free space on the filesystem that will hold a path, resolving to the nearest
# existing ancestor because the directory itself may not be created yet.
available_space_mb() {
  local path="${1:-/}"
  while [[ ! -d "${path}" && "${path}" != "/" && -n "${path}" ]]; do
    path="$(dirname "${path}")"
  done
  df -Pm "${path}" 2>/dev/null | awk 'NR==2 {print $4}'
}

preflight_disk_space() {
  local required available
  required="$(estimated_required_space_mb)"
  available="$(available_space_mb "${LNMP_SRC_DIR}")"
  if [[ ! "${available}" =~ ^[0-9]+$ ]]; then
    warn "Could not determine free space for ${LNMP_SRC_DIR}; skipping the disk-space check"
    return 0
  fi
  printf '  Build space in %s: %s MB available, about %s MB required\n' \
    "${LNMP_SRC_DIR}" "${available}" "${required}"
  if ((available < required)); then
    warn "Only ${available} MB is free for builds under ${LNMP_SRC_DIR}, but roughly ${required} MB is needed."
    warn "Free up space or point LNMP_SRC_DIR at a larger filesystem."
    [[ "${LNMP_ALLOW_LOW_DISK:-0}" == "1" ]] ||
      die "Insufficient build space; set LNMP_ALLOW_LOW_DISK=1 to continue anyway"
  fi
}

# The database components ship as official binary tarballs that exist only for
# some architectures. Failing here names the architecture instead of letting an
# empty URL surface as an unrelated download error mid-installation.
preflight_architecture() {
  case "${db_engine:-none}" in
    mysql)
      mysql_binary_url >/dev/null 2>&1 ||
        die "MySQL has no official binary package for $(uname -m); choose MariaDB or a different architecture"
      ;;
    mariadb)
      mariadb_binary_url >/dev/null 2>&1 ||
        die "MariaDB has no official binary package for $(uname -m); choose MySQL or a different architecture"
      ;;
  esac
}

run_preflight() {
  local ports="" port
  echo
  echo "Pre-installation checks:"
  command_exists curl || warn "curl was not found; dependency installation will attempt to install it"
  command_exists tar || warn "tar was not found; dependency installation will attempt to install it"
  preflight_architecture
  df -h / | awk 'NR==2 {print "  Disk available: "$4}'
  preflight_disk_space
  if command_exists free; then
    free -h | awk '/Mem:/ {print "  Memory: "$2", available: "$7}'
    free -m | awk '/Swap:/ { if ($2 == 0) print "  Swap: not configured; consider adding swap on low-memory systems" }'
  fi
  if has_component nginx; then
    ports="$(port_list_add_unique "${ports}" "${nginx_http_port}")"
    ports="$(port_list_add_unique "${ports}" "${nginx_https_port}")"
  fi
  case "${db_engine}" in
    mysql) has_component mysql && ports="$(port_list_add_unique "${ports}" "${mysql_port}")" ;;
    mariadb) has_component mariadb && ports="$(port_list_add_unique "${ports}" "${mariadb_port}")" ;;
  esac
  has_component redis && ports="$(port_list_add_unique "${ports}" "${redis_port}")"
  has_component memcached && ports="$(port_list_add_unique "${ports}" "${memcached_port}")"
  for port in ${ports}; do
    if command_exists lsof && lsof -i ":${port}" >/dev/null 2>&1; then
      warn "Port ${port} is already in use"
    fi
  done
  check_php_compatibility
  preflight_system_dependencies
}

check_php_compatibility() {
  local version os_id os_ver
  [[ -f /etc/os-release ]] || return 0
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-unknown}"
  os_ver="${VERSION_ID%%.*}"
  for version in ${php_versions:-}; do
    case "${version}" in
      54|55|56|70|71)
        warn "PHP $(php_version_label "${version}") is legacy software and may require older OpenSSL or libzip libraries on ${os_id} ${os_ver}. If compilation fails, use a compatible legacy OS image."
        ;;
    esac
  done
}

save_install_summary() {
  local summary="${ROOT_DIR}/install.txt"
  local pecl_failures
  pecl_failures="$(php_pecl_failure_summary 2>/dev/null || true)"
  {
    echo "LNMP install summary"
    date
    print_summary
    if [[ -n "${pecl_failures}" ]]; then
      echo
      echo "PECL extensions that failed to build (retry with ./addons.sh):"
      echo "  ${pecl_failures}"
    fi
    echo
    echo "Passwords:"
    [[ "${db_engine}" == "mysql" ]] && echo "  MySQL: ${mysql_password}"
    [[ "${db_engine}" == "mariadb" ]] && echo "  MariaDB: ${mariadb_password}"
    if [[ "${install_redis}" == "y" ]]; then
      [[ -n "${redis_password}" ]] && echo "  Redis: ${redis_password}" || echo "  Redis: no password configured"
    fi
  } > "${summary}"
  chmod 600 "${summary}"
}

report_pecl_failures() {
  local failures
  failures="$(php_pecl_failure_summary 2>/dev/null || true)"
  [[ -n "${failures}" ]] || return 0
  warn "These PECL extensions did not build and are NOT installed: ${failures}"
  warn "Retry them individually with ./addons.sh; the list is also recorded in install.txt."
}

print_passwords_to_tty() {
  local tty="/dev/tty"
  [[ -w "${tty}" ]] || return 0
  {
    echo "Save these passwords:"
    [[ "${db_engine}" == "mysql" ]] && echo "  MySQL: ${mysql_password}"
    [[ "${db_engine}" == "mariadb" ]] && echo "  MariaDB: ${mariadb_password}"
    if [[ "${install_redis}" == "y" ]]; then
      [[ -n "${redis_password}" ]] && echo "  Redis: ${redis_password}" || echo "  Redis: no password configured"
    fi
  } > "${tty}"
}
