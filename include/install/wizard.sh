#!/usr/bin/env bash

prompt_password_value() {
  local message="$1"
  local min_length="${2:-6}"
  local value
  while :; do
    value="$(prompt_input "${message} (leave empty to generate one)" "")"
    if validate_password_or_random "${value}" "${min_length}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "The password must be at least ${min_length} characters and must not contain single quotes or backslashes"
  done
}

prompt_optional_password_value() {
  local message="$1"
  local min_length="${2:-6}"
  local value
  while :; do
    value="$(prompt_input "${message} (leave empty to disable authentication)" "")"
    if validate_password_or_random "${value}" "${min_length}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "The password must be empty or at least ${min_length} characters, without single quotes or backslashes"
  done
}

prompt_port_value() {
  local message="$1" default="$2" value
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_port "${value}"; then
      printf '%s' "$((10#${value}))"
      return 0
    fi
    warn "The port must be an integer from 1 through 65535"
  done
}

selected_service_ports() {
  local ports=""
  if has_component nginx; then
    ports="$(port_list_add_unique "${ports}" "${nginx_http_port}")"
    # Keep the duplicate here so conflict validation can detect HTTP=HTTPS.
    ports="${ports} ${nginx_https_port}"
  fi
  case "${db_engine:-none}" in
    mysql) ports="${ports} ${mysql_port}" ;;
    mariadb) ports="${ports} ${mariadb_port}" ;;
  esac
  has_component redis && ports="${ports} ${redis_port}"
  has_component memcached && ports="${ports} ${memcached_port}"
  printf '%s' "${ports# }"
}

validate_selected_service_ports() {
  local ports port duplicate
  ports="$(selected_service_ports)"
  for port in ${ports}; do
    validate_port "${port}" || { warn "Invalid service port: ${port}"; return 1; }
  done
  duplicate="$(printf '%s\n' ${ports} | sort | uniq -d | head -1)"
  [[ -z "${duplicate}" ]] || { warn "Selected services use the same port: ${duplicate}"; return 1; }
}

prompt_php_versions() {
  local default_versions input normalized
  cat >&2 <<EOF

Multiple PHP versions can be installed side by side.
EOF
  default_versions="$(normalize_php_versions "${php_versions}" 2>/dev/null || printf '84')"
  if [[ ! -t 0 || "${LNMP_SIMPLE_PROMPT:-}" == "1" ]]; then
    while :; do
      input="$(prompt_input "Select PHP versions" "${default_versions}")"
      if normalized="$(normalize_php_versions "${input}")"; then
        printf '%s' "${normalized}"
        return 0
      fi
      warn "Invalid PHP version selection"
    done
  fi
  normalized="$(prompt_multi_select "Select PHP versions" "${default_versions}" \
    "54|PHP 5.4" "55|PHP 5.5" "56|PHP 5.6" \
    "70|PHP 7.0" "71|PHP 7.1" "72|PHP 7.2" "73|PHP 7.3" "74|PHP 7.4" \
    "80|PHP 8.0" "81|PHP 8.1" "82|PHP 8.2" "83|PHP 8.3" "84|PHP 8.4" "85|PHP 8.5")"
  normalize_php_versions "${normalized}"
}

prompt_components() {
  prompt_multi_select "Select components to install" "${install_components}" \
    "nginx|Nginx" \
    "php|PHP (multiple versions)" \
    "mysql|MySQL official binary package [Recommended]" \
    "mariadb|MariaDB official binary package [Recommended]" \
    "redis|Redis" \
    "memcached|Memcached" \
    "certbot|Certbot certificate client" \
    "composer|Composer"
}

prompt_component_version() {
  local label="$1" current="$2" supported="$3" version entries=()
  for version in ${supported}; do
    entries+=("${version}|${label} ${version}")
  done
  prompt_select "Select the ${label} version" "${current}" "${entries[@]}"
}

has_component() {
  local component="$1"
  [[ " ${install_components} " == *" ${component} "* ]]
}

prompt_php_profile() {
  prompt_select "Select a PHP installation profile" "${php_profile}" \
    "minimal|Minimal: PHP-FPM and common database drivers" \
    "web|Recommended: common Laravel, WordPress, and ThinkPHP extensions" \
    "full|Full: most extensions commonly provided by hosting panels" \
    "custom|Custom: select extensions manually"
}

prompt_php_extension_set() {
  local builtin_entries pecl_entries entry selected_builtin selected_pecl
  builtin_entries=()
  pecl_entries=()
  while IFS= read -r entry; do
    builtin_entries+=("${entry}")
  done < <(php_extension_entries_args)
  while IFS= read -r entry; do
    pecl_entries+=("${entry}")
  done < <(php_pecl_entries_args)
  if [[ "${php_profile}" == "custom" ]]; then
    while :; do
      selected_builtin="$(LNMP_ALLOW_BACK=1 prompt_multi_select "Select compiled PHP extensions" "${php_extensions}" "${builtin_entries[@]}")"
      [[ "${selected_builtin}" == "__BACK__" ]] && return 1
      selected_pecl="$(LNMP_ALLOW_BACK=1 prompt_multi_select "Select PHP PECL and additional extensions" "${php_pecl_extensions}" "${pecl_entries[@]}")"
      [[ "${selected_pecl}" == "__BACK__" ]] && continue
      php_extensions="${selected_builtin}"
      php_pecl_extensions="${selected_pecl}"
      return 0
    done
  else
    php_extensions="$(php_profile_builtin_extensions "${php_profile}")"
    php_pecl_extensions="$(php_profile_pecl_extensions "${php_profile}")"
  fi
}

prompt_php_configuration() {
  local selected_profile
  while :; do
    php_versions="$(prompt_php_versions)"
    while :; do
      selected_profile="$(LNMP_ALLOW_BACK=1 prompt_php_profile)"
      [[ "${selected_profile}" == "__BACK__" ]] && break
      php_profile="${selected_profile}"
      if prompt_php_extension_set; then
        return 0
      fi
    done
  done
}

choose_database() {
  local choice default_choice
  case "${db_engine}" in
    mariadb) default_choice=2 ;;
    none) default_choice=0 ;;
    *) default_choice=1 ;;
  esac
  choice="$(prompt_select "Select a database" "${default_choice}" \
    "1|MySQL ${mysql_ver}" \
    "2|MariaDB ${mariadb_ver}" \
    "0|Do not install a database")"
  case "${choice}" in
    1) printf 'mysql' ;;
    2) printf 'mariadb' ;;
    0) printf 'none' ;;
  esac
}
