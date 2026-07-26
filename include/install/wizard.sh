#!/usr/bin/env bash

prompt_password_value() {
  local message="$1"
  local min_length="${2:-6}"
  local value attempt=0
  while :; do
    value="$(prompt_secret_input "${message} (leave empty to generate one)")"
    if validate_password_or_random "${value}" "${min_length}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "The password must be at least ${min_length} characters and must not contain single quotes or backslashes"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "password"
  done
}

prompt_optional_password_value() {
  local message="$1"
  local min_length="${2:-6}"
  local value attempt=0
  while :; do
    value="$(prompt_secret_input "${message} (leave empty to disable authentication)")"
    # This prompt is only used for Redis, whose password becomes a bare token
    # in redis.conf, so it needs the stricter character set.
    if validate_redis_password "${value}" && validate_password_or_random "${value}" "${min_length}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "The password must be empty or ${min_length}-512 characters from A-Z a-z 0-9 . _ ~ ! @ % ^ * + = : , / - (no spaces, quotes, or #)"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "password"
  done
}

prompt_port_value() {
  local message="$1" default="$2" value attempt=0
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_port "${value}"; then
      printf '%s' "$((10#${value}))"
      return 0
    fi
    warn "The port must be an integer from 1 through 65535"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "port"
  done
}

prompt_bind_address_value() {
  local message="$1" default="$2" value attempt=0
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_bind_address "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "Enter an IP address or host name without spaces or shell metacharacters"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "bind address"
  done
}

prompt_username_value() {
  local message="$1" default="$2" value attempt=0
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_unix_username "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "Use a lowercase account name of at most 32 characters starting with a letter or underscore (letters, digits, underscore, hyphen)"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "account name"
  done
}

prompt_timezone_value() {
  local message="$1" default="$2" value attempt=0
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_timezone "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "Enter an IANA time zone such as Asia/Shanghai or UTC"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "time zone"
  done
}

prompt_memory_mb_value() {
  local message="$1" default="$2" value attempt=0
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_memory_mb "${value}"; then
      printf '%s' "$((10#${value}))"
      return 0
    fi
    warn "The memory size must be an integer from 1 through 1048576 (MB)"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "memory size"
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
  # ${ports} is a space-separated list; the split into one port per line is intended.
  # shellcheck disable=SC2086
  duplicate="$(printf '%s\n' ${ports} | sort | uniq -d | head -1)"
  [[ -z "${duplicate}" ]] || { warn "Selected services use the same port: ${duplicate}"; return 1; }
}

prompt_php_versions() {
  local default_versions input normalized entry attempt=0
  local entries=()
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
      attempt=$((attempt + 1))
      prompt_retry_guard "${attempt}" "PHP version selection"
    done
  fi
  while IFS= read -r entry; do
    entries+=("${entry}")
  done < <(php_version_entries)
  normalized="$(prompt_multi_select "Select PHP versions" "${default_versions}" "${entries[@]}")"
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
    "composer|Composer" \
    "fail2ban|fail2ban brute-force protection"
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
