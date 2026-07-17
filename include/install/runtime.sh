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

run_install() {
  require_root
  export TZ="${timezone}"
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
  apply_php_security || true
  configure_firewall || true
  save_runtime_options
  save_install_summary
}

run_preflight() {
  local ports="" port
  echo
  echo "Pre-installation checks:"
  command_exists curl || warn "curl was not found; dependency installation will attempt to install it"
  command_exists tar || warn "tar was not found; dependency installation will attempt to install it"
  df -h / | awk 'NR==2 {print "  Disk available: "$4}'
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
  {
    echo "LNMP install summary"
    date
    print_summary
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
