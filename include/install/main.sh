#!/usr/bin/env bash

show_help() {
  cat <<EOF
LNMP Interactive Installer ${VERSION}

Usage:
  ./install.sh

The installer is step-by-step interactive. It intentionally does not require
install choices as command-line parameters.
EOF
}

run_install_entrypoint() {
  case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    -v|--version) echo "${VERSION}"; exit 0 ;;
    "") ;;
    *) warn "Installation choices are interactive; command-line arguments were ignored." ;;
  esac

  print_header
  echo "Press Enter to accept defaults. Paths are read from options.conf. Empty database passwords are generated; an empty Redis password disables authentication."

  install_components="$(prompt_components)"
  if has_component nginx; then
    nginx_ver="$(prompt_component_version Nginx "${nginx_ver}" "${nginx_versions}")"
  fi
  timezone="$(prompt_input "Time zone" "${timezone}")"
  user="$(prompt_input "Service user" "${user}")"
  group="$(prompt_input "Service group" "${group}")"

  db_engine="none"
  if has_component mysql && has_component mariadb; then
    db_engine="$(choose_database)"
  elif has_component mysql; then
    db_engine="mysql"
  elif has_component mariadb; then
    db_engine="mariadb"
  fi
  if [[ "${db_engine}" == "mysql" ]]; then
    mysql_ver="$(prompt_component_version MySQL "${mysql_ver}" "${mysql_versions}")"
    mysql_password="$(prompt_password_value "MySQL password")"
    [[ -z "${mysql_password}" ]] && mysql_password="$(random_password 20)"
  elif [[ "${db_engine}" == "mariadb" ]]; then
    mariadb_ver="$(prompt_component_version MariaDB "${mariadb_ver}" "${mariadb_versions}")"
    mariadb_password="$(prompt_password_value "MariaDB password")"
    [[ -z "${mariadb_password}" ]] && mariadb_password="$(random_password 20)"
  fi

  if has_component php; then
    prompt_php_configuration
  fi
  install_redis="$(has_component redis && printf y || printf n)"
  if has_component redis; then
    redis_ver="$(prompt_component_version Redis "${redis_ver}" "${redis_versions}")"
    redis_bind="$(prompt_input "Redis bind address" "${redis_bind}")"
    redis_password="$(prompt_optional_password_value "Redis password")"
  fi
  install_memcached="$(has_component memcached && printf y || printf n)"
  if has_component memcached; then
    memcached_bind="$(prompt_input "Memcached bind address" "${memcached_bind}")"
    memcached_memory="$(prompt_input "Memcached memory (MB)" "${memcached_memory}")"
  fi
  install_composer="$(has_component composer && printf y || printf n)"
  customize_service_ports="$(prompt_yes_no "Change the default service ports?" "${customize_service_ports:-n}")"
  if [[ "${customize_service_ports}" == "y" ]]; then
    if has_component nginx; then
      nginx_http_port="$(prompt_port_value "Nginx HTTP port" "${nginx_http_port}")"
      nginx_https_port="$(prompt_port_value "Nginx HTTPS port" "${nginx_https_port}")"
    fi
    case "${db_engine}" in
      mysql) mysql_port="$(prompt_port_value "MySQL port" "${mysql_port}")" ;;
      mariadb) mariadb_port="$(prompt_port_value "MariaDB port" "${mariadb_port}")" ;;
    esac
    has_component redis && redis_port="$(prompt_port_value "Redis port" "${redis_port}")"
    has_component memcached && memcached_port="$(prompt_port_value "Memcached port" "${memcached_port}")"
  fi
  validate_selected_service_ports || die "Invalid service port configuration; restart the installer"
  manage_firewall="$(prompt_yes_no "Configure the firewall to allow web ports?" "${manage_firewall:-n}")"
  if [[ "${manage_firewall}" == "y" ]]; then
    open_database_port="$(prompt_yes_no "Allow the database port through the firewall?" "${open_database_port:-n}")"
    open_redis_port="$(prompt_yes_no "Allow the Redis port through the firewall?" "${open_redis_port:-n}")"
    open_memcached_port="$(prompt_yes_no "Allow the Memcached port through the firewall?" "${open_memcached_port:-n}")"
  fi
  php_security_hardening="$(prompt_yes_no "Enable PHP security hardening?" "${php_security_hardening:-y}")"
  refresh_component_version_urls || die "An unsupported component version was selected"

  setup_install_logging
  print_summary
  print_existing_install_status
  print_source_cache_status
  run_preflight
  confirm="$(prompt_yes_no "Start the installation?" "n")"
  [[ "${confirm}" == "y" ]] || die "Installation cancelled"

  if [[ "${LNMP_DRY_RUN:-}" == "1" ]]; then
    save_runtime_options
    ok "Dry run completed; no software was installed."
    exit 0
  fi

  run_install

  ok "Installation completed."
  print_passwords_to_tty
  echo "Passwords were saved to: ${ROOT_DIR}/install.txt"
  echo "Manage virtual hosts with: ./vhost.sh"
}
