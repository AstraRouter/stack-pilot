#!/usr/bin/env bash

memcached_service_file_path() {
  printf '%s' "${MEMCACHED_SERVICE_FILE_OVERRIDE:-/etc/systemd/system/memcached.service}"
}

memcached_install_complete() {
  [[ -x "${memcached_install_dir}/bin/memcached" ]] || return 1
  [[ -f "$(memcached_service_file_path)" ]] || return 1
}

install_memcached_server() {
  if memcached_install_complete; then
    warn "Memcached is already installed: ${memcached_install_dir}"
    return 0
  fi
  detect_os
  ensure_user_group memcached memcached
  mkdir -p "${memcached_install_dir}/bin" "${memcached_log_dir}" "${pid_dir}"
  if [[ "${PM}" == "apt-get" ]]; then
    install_packages memcached
    cp "$(command -v memcached)" "${memcached_install_dir}/bin/memcached"
  else
    install_packages memcached
    cp "$(command -v memcached)" "${memcached_install_dir}/bin/memcached"
  fi
  write_memcached_service
  link_executable_to_bin "${memcached_install_dir}/bin/memcached" memcached
  systemctl_reload_or_restart memcached
}

write_memcached_service() {
  cat > "$(memcached_service_file_path)" <<EOF
[Unit]
Description=Memcached
After=network.target

[Service]
User=memcached
Group=memcached
ExecStart=${memcached_install_dir}/bin/memcached -m ${memcached_memory} -l ${memcached_bind} -p ${memcached_port} -u memcached -P ${pid_dir}/memcached.pid
PIDFile=${pid_dir}/memcached.pid

[Install]
WantedBy=multi-user.target
EOF
}
