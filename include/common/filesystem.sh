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
  chmod 1777 "${pid_dir:-/data/pid}" "${sock_dir:-/data/sock}" 2>/dev/null || true
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
