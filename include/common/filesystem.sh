#!/usr/bin/env bash

render_template_file() {
  local template="$1"
  local output="$2"
  shift 2
  local content key value
  [[ -f "${template}" ]] || die "Template not found: ${template}"
  content="$(cat "${template}")"
  while (($# >= 2)); do
    key="$1"
    value="$2"
    content="${content//\{\{${key}\}\}/${value}}"
    shift 2
  done
  printf '%s\n' "${content}" > "${output}"
}

systemctl_reload_or_restart() {
  local service="$1"
  if command_exists systemctl; then
    systemctl daemon-reload || true
    if ! systemctl restart "${service}"; then
      warn "${service} failed to start. Recent status and logs follow:"
      systemctl status "${service}" --no-pager -l 2>&1 | tail -40 >&2 || true
      journalctl -u "${service}" --no-pager -n 60 2>&1 >&2 || true
      return 1
    fi
    systemctl enable "${service}" >/dev/null 2>&1 || true
  else
    service "${service}" restart
  fi
}

safe_mkdir() {
  local dir="$1"
  mkdir -p "${dir}"
}

init_layout_dirs() {
  mkdir -p \
    "${services_base_dir:-/usr/local/services}" \
    "${data_base_dir:-/usr/local/data}" \
    "${runtime_base_dir:-/data}" \
    "${pid_dir:-/data/pid}" \
    "${sock_dir:-/data/sock}" \
    "${logs_dir:-/data/logs}" \
    "${nginx_log_dir:-/data/logs/nginx}" \
    "${php_log_dir:-/data/logs/php}" \
    "${mysql_log_dir:-/data/logs/mysql}" \
    "${mariadb_log_dir:-/data/logs/mariadb}" \
    "${redis_log_dir:-/data/logs/redis}" \
    "${memcached_log_dir:-/data/logs/memcached}"
  chmod 755 "${runtime_base_dir:-/data}" "${logs_dir:-/data/logs}" 2>/dev/null || true
  # 0755, never 1777: a world-writable socket directory lets any local account
  # pre-create mysql.sock and intercept credentials from local clients, and a
  # world-writable pid directory allows startup denial-of-service and symlink
  # attacks. Services that run as a non-root user are granted access
  # individually through grant_runtime_dir_access.
  chmod 755 "${pid_dir:-/data/pid}" "${sock_dir:-/data/sock}" 2>/dev/null || true
}

# Let one service user create and replace its runtime files without opening the
# directory to every local account. setgid keeps new entries in the service
# group even when root creates them.
grant_runtime_dir_access() {
  local dir="$1"
  local group="$2"
  [[ -n "${dir}" && -d "${dir}" ]] || return 0
  getent group "${group}" >/dev/null 2>&1 || {
    warn "Group ${group} does not exist; leaving ${dir} owned by root"
    return 0
  }
  chown "root:${group}" "${dir}" 2>/dev/null || true
  chmod 2775 "${dir}" 2>/dev/null || true
}

# Backups and pre-upgrade snapshots contain database dumps, options.conf, and
# redis.conf, all of which hold plaintext credentials. The mode is set
# explicitly rather than left to the caller's umask: a tool started with the
# default root umask of 022 would otherwise publish 0644 archives that every
# local account can read, and a directory created by an earlier version stays
# 0755 no matter what umask the current run uses.
ensure_private_dir() {
  local dir="$1"
  [[ -n "${dir}" ]] || return 1
  mkdir -p "${dir}"
  chmod 700 "${dir}" 2>/dev/null ||
    warn "Could not restrict permissions on ${dir}; confirm no other account can read it"
}

protect_private_file() {
  local file="$1"
  [[ -e "${file}" ]] || return 0
  chmod 600 "${file}" 2>/dev/null ||
    warn "Could not restrict permissions on ${file}; confirm no other account can read it"
}

prepare_service_log_file() {
  local file="$1"
  local owner="$2"
  local group="$3"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  chown "${owner}:${group}" "$(dirname "${file}")" "${file}" 2>/dev/null || true
}

directory_has_entries() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1
  [[ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}
