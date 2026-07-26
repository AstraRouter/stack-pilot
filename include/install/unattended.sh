#!/usr/bin/env bash

# Unattended installation.
#
# Every answer comes from options.conf instead of a prompt, so the file that a
# finished install writes back can reproduce that install on another host or
# from CI. Nothing is guessed: a value the wizard would have asked for is
# validated here, and the run stops with a message naming the option rather than
# failing later inside a build.

LNMP_INSTALLABLE_COMPONENTS="nginx php mysql mariadb redis memcached certbot composer fail2ban"

# The wizard derives these from the component selection, so unattended mode must
# derive them the same way rather than trusting stale values in the file.
resolve_unattended_components() {
  local normalized
  normalized="$(normalize_values "${install_components:-}" "${LNMP_INSTALLABLE_COMPONENTS}")" ||
    die "install_components contains an unsupported entry: ${install_components:-empty}. Valid: ${LNMP_INSTALLABLE_COMPONENTS}"
  install_components="${normalized}"

  install_redis="$(has_component redis && printf y || printf n)"
  install_memcached="$(has_component memcached && printf y || printf n)"
  install_composer="$(has_component composer && printf y || printf n)"

  if has_component mysql && has_component mariadb; then
    die "install_components lists both mysql and mariadb; only one database engine can be installed"
  elif has_component mysql; then
    db_engine="mysql"
  elif has_component mariadb; then
    db_engine="mariadb"
  else
    db_engine="none"
  fi
}

# An empty password means "generate one", exactly as in the wizard. A supplied
# password is validated here because no prompt loop rejected it first.
resolve_unattended_passwords() {
  case "${db_engine}" in
    mysql)
      if [[ -z "${mysql_password}" ]]; then
        mysql_password="$(random_password 20)"
      else
        validate_password_or_random "${mysql_password}" 6 ||
          die "mysql_password must be at least 6 characters and must not contain single quotes or backslashes"
      fi
      ;;
    mariadb)
      if [[ -z "${mariadb_password}" ]]; then
        mariadb_password="$(random_password 20)"
      else
        validate_password_or_random "${mariadb_password}" 6 ||
          die "mariadb_password must be at least 6 characters and must not contain single quotes or backslashes"
      fi
      ;;
  esac
  if has_component redis; then
    validate_redis_password "${redis_password:-}" ||
      die "redis_password must be empty or 6-512 characters from A-Z a-z 0-9 . _ ~ ! @ % ^ * + = : , / - (no spaces, quotes, or #)"
  fi
}

validate_unattended_options() {
  validate_timezone "${timezone:-}" || die "Invalid timezone: ${timezone:-empty}"
  validate_unix_username "${user:-}" || die "Invalid user: ${user:-empty}"
  validate_unix_username "${group:-}" || die "Invalid group: ${group:-empty}"
  validate_path "${wwwroot_dir:-}" || die "Invalid wwwroot_dir: ${wwwroot_dir:-empty}"
  validate_path "${backup_dir:-}" || die "Invalid backup_dir: ${backup_dir:-empty}"

  if has_component php; then
    php_versions="$(normalize_php_versions "${php_versions:-}")" ||
      die "Invalid php_versions: ${php_versions:-empty}. Supported: $(php_supported_versions)"
    validate_choice "${php_profile:-}" "minimal web full custom" ||
      die "Invalid php_profile: ${php_profile:-empty} (expected minimal, web, full, or custom)"
    assert_php_fpm_tunables
  fi
  if has_component redis; then
    validate_bind_address "${redis_bind:-}" || die "Invalid redis_bind: ${redis_bind:-empty}"
  fi
  if has_component memcached; then
    validate_bind_address "${memcached_bind:-}" || die "Invalid memcached_bind: ${memcached_bind:-empty}"
    validate_memory_mb "${memcached_memory:-}" || die "Invalid memcached_memory: ${memcached_memory:-empty}"
  fi
  if has_component nginx; then
    # Covers the request size limit, HSTS, HTTP/3, and the rate-limit values.
    assert_nginx_policy_options
    validate_positive_integer "${nginx_worker_connections:-10240}" 1048576 ||
      die "Invalid nginx_worker_connections: ${nginx_worker_connections}"
    validate_positive_integer "${nginx_keepalive_timeout:-65}" 86400 ||
      die "Invalid nginx_keepalive_timeout: ${nginx_keepalive_timeout}"
  fi
  if has_component fail2ban; then
    assert_fail2ban_options
  fi
  [[ "${manage_logrotate:-y}" != "y" ]] || render_logrotate_config >/dev/null

  local flag
  for flag in manage_firewall open_database_port open_redis_port open_memcached_port php_security_hardening; do
    normalize_yes_no "${!flag:-n}" n >/dev/null || die "Invalid ${flag}: ${!flag} (expected y or n)"
  done

  validate_selected_service_ports || die "Invalid service port configuration in ${LNMP_OPTIONS_FILE}"
  refresh_component_version_urls || die "options.conf selects an unsupported component version"
}

run_unattended_install() {
  info "Unattended installation driven by ${LNMP_OPTIONS_FILE}"
  require_root
  resolve_unattended_components
  resolve_unattended_passwords
  validate_unattended_options

  setup_install_logging
  print_summary
  print_existing_install_status
  print_source_cache_status
  run_preflight

  if [[ "${LNMP_DRY_RUN:-}" == "1" ]]; then
    save_runtime_options
    ok "Dry run completed; no software was installed."
    return 0
  fi

  run_install
  ok "Unattended installation completed."
  report_pecl_failures
  # Generated passwords would otherwise exist only in this run's output, which
  # in CI is usually discarded.
  echo "Passwords were saved to: ${ROOT_DIR}/install.txt"
}
