#!/usr/bin/env bash

# One command that answers "what is actually running here?" — versions, service
# state, listening ports, certificate expiry, and disk usage. Previously this
# needed systemctl, ss, openssl, and a read of options.conf, run separately for
# each component.

status_service_state() {
  local service="$1"
  if ! command_exists systemctl; then
    printf 'unknown (no systemctl)'
    return 0
  fi
  if systemctl is-active --quiet "${service}" 2>/dev/null; then
    printf 'running'
  elif systemctl list-unit-files "${service}.service" >/dev/null 2>&1 &&
       systemctl cat "${service}" >/dev/null 2>&1; then
    printf 'stopped'
  else
    printf 'not installed'
  fi
}

status_port_listening() {
  local port="$1"
  [[ -n "${port}" ]] || return 1
  if command_exists ss; then
    ss -ltn 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {found=1} END {exit !found}'
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {found=1} END {exit !found}'
  else
    return 2
  fi
}

status_port_label() {
  local port="$1" state
  [[ -n "${port}" ]] || { printf 'n/a'; return 0; }
  status_port_listening "${port}"
  state=$?
  case "${state}" in
    0) printf '%s listening' "${port}" ;;
    1) printf '%s not listening' "${port}" ;;
    *) printf '%s (unable to check)' "${port}" ;;
  esac
}

status_component_version() {
  local install_dir="$1"
  read_component_version_marker "${install_dir}" 2>/dev/null || printf 'unknown'
}

status_component_line() {
  local label="$1" install_dir="$2" service="$3" port="${4:-}"
  [[ -d "${install_dir}" ]] || return 0
  printf '  %-11s %-10s %-12s %s\n' \
    "${label}" "$(status_component_version "${install_dir}")" \
    "$(status_service_state "${service}")" "$(status_port_label "${port}")"
}

print_status_system() {
  echo "System:"
  printf '  OS:        %s %s (%s)\n' \
    "$(os_release_value ID 2>/dev/null || printf unknown)" \
    "$(os_release_value VERSION_ID 2>/dev/null || printf unknown)" \
    "$(uname -m)"
  printf '  Kernel:    %s\n' "$(uname -r)"
  printf '  Uptime:    %s\n' "$(uptime 2>/dev/null | sed 's/^[[:space:]]*//' || printf unknown)"
  printf '  Time zone: %s\n' "${timezone:-unset}"
}

print_status_components() {
  local version prefix
  echo
  echo "Components:"
  printf '  %-11s %-10s %-12s %s\n' NAME VERSION STATE PORT
  status_component_line Nginx "${nginx_install_dir}" nginx "${nginx_http_port:-80}"
  status_component_line MySQL "${mysql_install_dir}" mysqld "${mysql_port:-3306}"
  status_component_line MariaDB "${mariadb_install_dir}" mariadb "${mariadb_port:-3306}"
  status_component_line Redis "${redis_install_dir}" redis-server "${redis_port:-6379}"
  status_component_line Memcached "${memcached_install_dir}" memcached "${memcached_port:-11211}"
  for version in $(installed_php_versions); do
    prefix="$(php_install_dir_for_version "${version}")"
    printf '  %-11s %-10s %-12s %s\n' \
      "PHP $(php_version_label "${version}")" \
      "$("${prefix}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null || printf unknown)" \
      "$(status_service_state "$(php_service_name "${version}")")" \
      "$(status_port_label "$(php_fpm_port "${version}")")"
  done
  if command_exists php; then
    printf '  CLI php:    %s\n' "$(php -r 'echo PHP_VERSION;' 2>/dev/null || printf unknown)"
  fi
  if [[ -x "${composer_install_dir}/composer" ]]; then
    printf '  Composer:   %s\n' \
      "$("${composer_install_dir}/composer" --version --no-interaction 2>/dev/null | head -1 || printf installed)"
  fi
}

# Read the expiry straight from the certificate rather than from certbot, so it
# also reports certificates that were installed by hand.
status_certificate_expiry() {
  local cert="$1" end_date end_epoch now_epoch days
  command_exists openssl || { printf 'openssl not available'; return 0; }
  end_date="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)"
  [[ -n "${end_date}" ]] || { printf 'unreadable'; return 0; }
  end_epoch="$(date -d "${end_date}" +%s 2>/dev/null || printf '')"
  if [[ -z "${end_epoch}" ]]; then
    printf 'expires %s' "${end_date}"
    return 0
  fi
  now_epoch="$(date +%s)"
  days=$(((end_epoch - now_epoch) / 86400))
  if ((days < 0)); then
    printf 'EXPIRED %s days ago (%s)' "$((-days))" "${end_date}"
  else
    printf '%s days left (%s)' "${days}" "${end_date}"
  fi
}

print_status_sites() {
  local conf domain cert
  echo
  echo "Virtual hosts:"
  if [[ ! -d "$(vhost_conf_dir)" ]]; then
    echo "  none (Nginx is not installed)"
    return 0
  fi
  for conf in "$(vhost_conf_dir)"/*.conf; do
    [[ -f "${conf}" ]] || continue
    domain="$(basename "${conf}" .conf)"
    [[ "${domain}" == "default" ]] && continue
    cert="$(ssl_cert_fullchain_path "${domain}")"
    if [[ -f "${cert}" ]]; then
      printf '  %-30s HTTPS  %s\n' "${domain}" "$(status_certificate_expiry "${cert}")"
    else
      printf '  %-30s HTTP   no certificate\n' "${domain}"
    fi
  done
}

status_path_usage() {
  local path="$1"
  [[ -d "${path}" ]] || { printf 'absent'; return 0; }
  printf '%s' "$(du -sh "${path}" 2>/dev/null | awk '{print $1}')"
}

print_status_storage() {
  local newest count
  echo
  echo "Storage:"
  printf '  Web root:  %-8s %s\n' "$(status_path_usage "${wwwroot_dir}")" "${wwwroot_dir}"
  printf '  Logs:      %-8s %s\n' "$(status_path_usage "${logs_dir}")" "${logs_dir}"
  printf '  Backups:   %-8s %s\n' "$(status_path_usage "${backup_dir}")" "${backup_dir}"
  printf '  Sources:   %-8s %s\n' "$(status_path_usage "${LNMP_SRC_DIR}")" "${LNMP_SRC_DIR}"
  if [[ -d "${backup_dir:-}" ]]; then
    count="$(find "${backup_dir}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql' \) 2>/dev/null | wc -l | tr -d ' ')"
    newest="$(find "${backup_dir}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql' \) 2>/dev/null | sort -r | head -1)"
    printf '  Backup files: %s%s\n' "${count}" "${newest:+, newest $(basename "${newest}")}"
  fi
  # A report must never be the thing that fails: an absent runtime directory or
  # a df that does not understand these flags is not worth aborting for.
  df -Ph "${runtime_base_dir:-/data}" 2>/dev/null |
    awk 'NR==2 {printf "  Filesystem: %s used of %s (%s) on %s\n", $3, $2, $5, $6}' || true
}

print_status_maintenance() {
  echo
  echo "Maintenance:"
  if [[ -f "$(logrotate_config_path)" ]]; then
    printf '  Log rotation: configured (%s)\n' "$(logrotate_config_path)"
  else
    printf '  Log rotation: NOT configured; logs under %s will grow without bound\n' "${logs_dir}"
  fi
  if [[ -f "$(fail2ban_jail_path)" ]]; then
    printf '  fail2ban:     %s\n' "$(status_service_state fail2ban)"
  else
    printf '  fail2ban:     not configured\n'
  fi
  local crontab_entries
  crontab_entries="$(crontab -l 2>/dev/null || true)"
  if command_exists systemctl && systemctl is-enabled --quiet lnmp-certbot-renew.timer 2>/dev/null; then
    printf '  Cert renewal: systemd timer enabled\n'
  elif [[ "${crontab_entries}" == *"certbot renew"* ]]; then
    printf '  Cert renewal: cron job installed\n'
  else
    printf '  Cert renewal: not scheduled\n'
  fi
}

print_status_report() {
  print_status_system
  print_status_components
  print_status_sites
  print_status_storage
  print_status_maintenance
}
