#!/usr/bin/env bash

print_summary() {
  cat <<EOF

Installation summary:
  Nginx:      ${nginx_install_dir} (${nginx_ver}), HTTP=${nginx_http_port}, HTTPS=${nginx_https_port}
  Components: ${install_components}
  PHP:        ${php_versions}, profile=${php_profile}, base=${php_install_base}
  PHP ext:    ${php_extensions}
  PECL ext:   ${php_pecl_extensions}
  Database:   ${db_engine}
  MySQL:      ${mysql_ver}, port=${mysql_port}, ${mysql_install_dir} / ${mysql_data_dir}
  MariaDB:    ${mariadb_ver}, port=${mariadb_port}, ${mariadb_install_dir} / ${mariadb_data_dir}
  Redis:      ${install_redis}, ${redis_ver}, port=${redis_port}, ${redis_install_dir} / ${redis_data_dir}
  Memcached:  ${install_memcached}, port=${memcached_port}, ${memcached_install_dir}
  Composer:   ${install_composer}, ${composer_install_dir}
  Web root:   ${wwwroot_dir}
  Runtime:    pid=${pid_dir} sock=${sock_dir}
  Logs:       ${logs_dir}
  User/group: ${user}:${group}
EOF
}

component_state() {
  local complete="$1"
  local install_path="${2:-}"
  local data_path="${3:-}"
  if "${complete}" >/dev/null 2>&1; then
    printf 'installed'
  elif [[ -n "${install_path}" && -e "${install_path}" ]] || [[ -n "${data_path}" && -e "${data_path}" ]]; then
    printf 'incomplete'
  else
    printf 'not installed'
  fi
}

nginx_install_complete() {
  [[ -x "${nginx_install_dir}/sbin/nginx" ]]
}

php_install_complete_for_version() {
  local version="${1//./}"
  [[ -x "$(php_install_dir_for_version "${version}")/sbin/php-fpm" ]]
}

composer_install_complete() {
  [[ -x "${composer_install_dir}/composer" || -x /usr/local/bin/composer ]]
}

print_existing_install_status() {
  local version php_dir
  echo
  echo "Existing installation check:"
  if has_component nginx; then
    echo "  Nginx:   $(component_state nginx_install_complete "${nginx_install_dir}") (${nginx_install_dir})"
  fi
  case "${db_engine}" in
    mysql)
      echo "  MySQL:   $(component_state mysql_install_complete "${mysql_install_dir}" "${mysql_data_dir}") (${mysql_install_dir})"
      ;;
    mariadb)
      echo "  MariaDB: $(component_state mariadb_install_complete "${mariadb_install_dir}" "${mariadb_data_dir}") (${mariadb_install_dir})"
      ;;
  esac
  if has_component php; then
    for version in ${php_versions}; do
      php_dir="$(php_install_dir_for_version "${version}")"
      if php_install_complete_for_version "${version}"; then
        echo "  PHP ${version}: installed (${php_dir})"
      elif [[ -e "${php_dir}" ]]; then
        echo "  PHP ${version}: incomplete (${php_dir})"
      else
        echo "  PHP ${version}: not installed (${php_dir})"
      fi
    done
  fi
  if has_component redis; then
    echo "  Redis:   $(component_state redis_install_complete "${redis_install_dir}" "${redis_data_dir}") (${redis_install_dir})"
  fi
  if has_component memcached; then
    echo "  Memcached: $(component_state memcached_install_complete "${memcached_install_dir}") (${memcached_install_dir})"
  fi
  if has_component composer; then
    echo "  Composer: $(component_state composer_install_complete "${composer_install_dir}") (${composer_install_dir})"
  fi
}

print_source_cache_item() {
  local label="$1"
  local url="$2"
  local output="${3:-${url##*/}}"
  echo "  ${label}: $(source_cache_state "${url}" "${output}") ($(source_cache_path "${url}" "${output}"))"
}

print_source_cache_status() {
  local version url
  echo
  echo "Source package cache:"
  if has_component nginx; then
    print_source_cache_item "Nginx" "${nginx_url}"
  fi
  case "${db_engine}" in
    mysql)
      url="$(mysql_binary_url)" && print_source_cache_item "MySQL" "${url}"
      ;;
    mariadb)
      url="$(mariadb_binary_url)" && print_source_cache_item "MariaDB" "${url}"
      ;;
  esac
  if has_component php; then
    for version in ${php_versions}; do
      url="$(php_source_url "${version}")" && print_source_cache_item "PHP ${version}" "${url}"
    done
  fi
  if has_component redis; then
    print_source_cache_item "Redis" "${redis_url}"
  fi
  if has_component composer; then
    print_source_cache_item "Composer installer" "https://getcomposer.org/installer" "composer-setup.php"
  fi
}
