#!/usr/bin/env bash

redis_requirepass_line() {
  local password="${1:-}"
  if [[ -n "${password}" ]]; then
    printf 'requirepass %s' "${password}"
  fi
  return 0
}

redis_cli_auth_args() {
  local password="${1:-}"
  if [[ -n "${password}" ]]; then
    printf -- '-a %s' "${password}"
  fi
  return 0
}

redis_service_file_path() {
  printf '%s' "${REDIS_SERVICE_FILE_OVERRIDE:-/etc/systemd/system/redis-server.service}"
}

redis_install_complete() {
  [[ -x "${redis_install_dir}/bin/redis-server" ]] || return 1
  [[ -x "${redis_install_dir}/bin/redis-cli" ]] || return 1
  [[ -f "${redis_install_dir}/etc/redis.conf" ]] || return 1
  [[ -f "$(redis_service_file_path)" ]] || return 1
}

cleanup_partial_redis_install() {
  if [[ -e "${redis_install_dir}" ]] || directory_has_entries "${redis_data_dir}"; then
    if ! redis_install_complete; then
      warn "An incomplete Redis installation was found; clean it before retrying: ${redis_install_dir} / ${redis_data_dir}"
      rm -rf "${redis_install_dir}" "${redis_data_dir}"
      return 0
    fi
  fi
}

install_redis_server() {
  if redis_install_complete; then
    local detected
    detected="$(${redis_install_dir}/bin/redis-server --version 2>/dev/null | extract_semver || true)"
    if should_skip_completed_install Redis "${redis_install_dir}" "${redis_ver}" "${detected}"; then
      warn "Redis is already installed: ${redis_install_dir}"
      return 0
    fi
  fi
  cleanup_partial_redis_install

  local archive build_dir redis_pass
  redis_pass="${redis_password:-}"
  redis_password="${redis_pass}"

  download_src "${redis_url}" "${redis_url##*/}" "${redis_sha256:-}"
  archive="${LNMP_SRC_DIR}/${redis_url##*/}"
  build_dir="$(mktemp -d)"
  extract_archive "${archive}" "${build_dir}"

  pushd "${build_dir}/redis-${redis_ver}" >/dev/null
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  make PREFIX="${redis_install_dir}" install
  popd >/dev/null
  rm -rf "${build_dir}"

  ensure_user_group redis redis
  init_layout_dirs
  mkdir -p "${redis_data_dir}" "${redis_install_dir}/etc" "${redis_log_dir}" "${pid_dir}"
  chown -R redis:redis "${redis_data_dir}" "${redis_log_dir}"

  cat > "${redis_install_dir}/etc/redis.conf" <<EOF
bind ${redis_bind}
protected-mode yes
port ${redis_port}
daemonize no
supervised no
pidfile ${pid_dir}/redis.pid
dir ${redis_data_dir}
logfile ${redis_log_dir}/redis.log
appendonly ${redis_appendonly}
$(redis_requirepass_line "${redis_pass}")
EOF

  write_redis_service
  write_component_version_marker "${redis_install_dir}" "${redis_ver}"
  link_executable_to_bin "${redis_install_dir}/bin/redis-cli" redis-cli
  link_executable_to_bin "${redis_install_dir}/bin/redis-server" redis-server
  systemctl_reload_or_restart redis-server
}

write_redis_service() {
  local auth_args shutdown_cmd
  auth_args="$(redis_cli_auth_args "${redis_password:-}")"
  shutdown_cmd="${redis_install_dir}/bin/redis-cli"
  [[ -n "${auth_args}" ]] && shutdown_cmd+=" ${auth_args}"
  shutdown_cmd+=" shutdown"
  cat > "$(redis_service_file_path)" <<EOF
[Unit]
Description=Redis persistent key-value database
After=network.target

[Service]
Type=simple
User=redis
Group=redis
ExecStart=${redis_install_dir}/bin/redis-server ${redis_install_dir}/etc/redis.conf --supervised no --daemonize no
ExecStop=${shutdown_cmd}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}
