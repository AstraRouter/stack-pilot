#!/usr/bin/env bash

validate_upgrade_install_dir() {
  local dir="${1:-}"
  [[ "${dir}" == /* ]] || return 1
  case "${dir}" in
    /|/usr|/usr/local|/opt|/var|/data) return 1 ;;
  esac
  [[ "$(basename "${dir}")" != "." && "$(basename "${dir}")" != ".." ]]
}

backup_before_upgrade() {
  local backup="${backup_dir}/upgrade-config-$(date '+%Y%m%d-%H%M%S').tar.gz"
  local paths=("${LNMP_OPTIONS_FILE:-${ROOT_DIR}/options.conf}" "${ROOT_DIR}/versions.conf") path
  mkdir -p "${backup_dir}"
  for path in "${ROOT_DIR}/install.txt" "$@"; do
    [[ -e "${path}" ]] && paths+=("${path}")
  done
  LC_ALL=C tar czf "${backup}" "${paths[@]}"
  [[ -s "${backup}" ]] || die "The pre-upgrade configuration backup failed"
  ok "Pre-upgrade configuration backup: ${backup}"
}

create_component_snapshot() {
  local label="$1" install_dir="$2"
  local parent base snapshot safe_label
  validate_upgrade_install_dir "${install_dir}" || die "Refusing to snapshot an unsafe upgrade path: ${install_dir}"
  [[ -d "${install_dir}" ]] || die "${label} is not installed and cannot be upgraded: ${install_dir}"
  mkdir -p "${backup_dir}"
  parent="$(dirname "${install_dir}")"
  base="$(basename "${install_dir}")"
  safe_label="$(printf '%s' "${label}" | tr '[:upper:] /:' '[:lower:]___')"
  snapshot="${backup_dir}/${safe_label}-tree-$(date '+%Y%m%d-%H%M%S')-$$-${RANDOM}.tar.gz"
  LC_ALL=C tar czf "${snapshot}" -C "${parent}" "${base}"
  [[ -s "${snapshot}" ]] || die "Failed to snapshot the ${label} installation directory"
  printf '%s' "${snapshot}"
}

control_upgrade_service() {
  local action="$1" service_name="$2"
  [[ -n "${service_name}" && "${UPGRADE_SKIP_SERVICE_CONTROL:-0}" != "1" ]] || return 0
  if command_exists systemctl; then
    systemctl "${action}" "${service_name}"
  else
    service "${service_name}" "${action}"
  fi
}

rollback_component_tree() {
  local label="$1" install_dir="$2" service_name="$3" snapshot="$4"
  local parent failed_dir
  validate_upgrade_install_dir "${install_dir}" || die "Refusing to restore an unsafe rollback path: ${install_dir}"
  [[ -s "${snapshot}" ]] || die "The ${label} rollback snapshot does not exist: ${snapshot}"
  parent="$(dirname "${install_dir}")"
  failed_dir="${install_dir}.failed-$(date '+%Y%m%d-%H%M%S')-$$-${RANDOM}"
  control_upgrade_service stop "${service_name}" >/dev/null 2>&1 || true
  [[ -e "${install_dir}" ]] && mv "${install_dir}" "${failed_dir}"
  if ! LC_ALL=C tar xzf "${snapshot}" -C "${parent}"; then
    warn "The ${label} snapshot could not be restored; the failed directory remains at ${failed_dir}"
    return 1
  fi
  control_upgrade_service restart "${service_name}" >/dev/null 2>&1 || {
    warn "The ${label} directory was restored, but its service failed to restart; inspect it immediately"
    return 1
  }
  warn "The ${label} upgrade failed and the previous version was restored; the failed directory remains at ${failed_dir}"
}

restore_snapshot_paths() {
  local snapshot="$1" install_dir="$2"
  shift 2
  local extract_dir base relative source target
  extract_dir="$(mktemp -d)"
  base="$(basename "${install_dir}")"
  if ! LC_ALL=C tar xzf "${snapshot}" -C "${extract_dir}"; then
    rm -rf "${extract_dir}"
    return 1
  fi
  for relative in "$@"; do
    source="${extract_dir}/${base}/${relative}"
    target="${install_dir}/${relative}"
    [[ -e "${source}" ]] || continue
    mkdir -p "$(dirname "${target}")"
    if [[ -d "${source}" ]]; then
      mkdir -p "${target}"
      cp -a "${source}/." "${target}/"
    else
      cp -a "${source}" "${target}"
    fi
  done
  rm -rf "${extract_dir}"
}

preserve_nginx_upgrade_config() {
  restore_snapshot_paths "$1" "$2" conf
}

preserve_redis_upgrade_config() {
  restore_snapshot_paths "$1" "$2" etc
}

preserve_php_upgrade_config() {
  restore_snapshot_paths "$1" "$2" etc
}

preserve_no_upgrade_config() { return 0; }

transactional_component_upgrade() {
  local label="$1" step="$2" install_dir="$3" service_name="$4" health_fn="$5" preserve_fn="$6" installer="$7"
  shift 7
  local snapshot was_done=n installer_status=0 had_errexit=n
  snapshot="$(create_component_snapshot "${label}" "${install_dir}")"
  is_step_done "${step}" && was_done=y
  clear_step_done "${step}"

  case "$-" in *e*) had_errexit=y ;; esac
  set +e
  (set -e; LNMP_FORCE_REINSTALL=1 "${installer}" "$@")
  installer_status=$?
  [[ "${had_errexit}" == "y" ]] && set -e

  if ((installer_status == 0)); then
    if "${preserve_fn}" "${snapshot}" "${install_dir}" && \
       control_upgrade_service restart "${service_name}" && \
       "${health_fn}"; then
      mark_step_done "${step}"
      ok "The ${label} upgrade and health check passed; rollback snapshot: ${snapshot}"
      return 0
    fi
  fi

  rollback_component_tree "${label}" "${install_dir}" "${service_name}" "${snapshot}" || \
    die "The ${label} upgrade failed and automatic rollback did not complete"
  [[ "${was_done}" == "y" ]] && mark_step_done "${step}"
  return 1
}

nginx_upgrade_health() {
  "${nginx_install_dir}/sbin/nginx" -t
}

redis_upgrade_health() {
  local response
  response="$(REDISCLI_AUTH="${redis_password:-}" "${redis_install_dir}/bin/redis-cli" \
    -h "${redis_bind:-127.0.0.1}" -p "${redis_port:-6379}" PING 2>/dev/null)"
  [[ "${response}" == "PONG" ]]
}

php_upgrade_health() {
  local short="${UPGRADE_PHP_SHORT:?}" prefix
  prefix="$(php_install_dir_for_version "${short}")"
  "${prefix}/bin/php" -v >/dev/null
  "${prefix}/sbin/php-fpm" -t --fpm-config "${prefix}/etc/php-fpm.conf"
}
