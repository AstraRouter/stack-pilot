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
  install_packages memcached
  command_exists memcached || die "The memcached package did not provide a memcached binary"
  cp "$(command -v memcached)" "${memcached_install_dir}/bin/memcached"
  write_memcached_service
  link_executable_to_bin "${memcached_install_dir}/bin/memcached" memcached
  systemctl_reload_or_restart memcached
}

write_memcached_service() {
  # These land unquoted in a root-owned systemd unit, and options.conf can set
  # them without ever passing through the wizard's prompts.
  validate_bind_address "${memcached_bind}" ||
    die "Invalid memcached bind address: ${memcached_bind}"
  validate_memory_mb "${memcached_memory}" ||
    die "Invalid memcached memory size in MB: ${memcached_memory}"
  validate_port "${memcached_port}" ||
    die "Invalid memcached port: ${memcached_port}"
  case "${memcached_bind}" in
    127.0.0.1|::1|localhost) ;;
    *) warn "Memcached is bound to ${memcached_bind} and has no authentication; restrict access at the firewall" ;;
  esac
  cat > "$(memcached_service_file_path)" <<EOF
[Unit]
Description=Memcached
After=network.target

[Service]
User=memcached
Group=memcached
ExecStart=${memcached_install_dir}/bin/memcached -m ${memcached_memory} -l ${memcached_bind} -p ${memcached_port} -u memcached

[Install]
WantedBy=multi-user.target
EOF
}
