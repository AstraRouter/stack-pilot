#!/usr/bin/env bash

mysql_service_file_path() {
  printf '%s' "${MYSQL_SERVICE_FILE_OVERRIDE:-/etc/systemd/system/mysqld.service}"
}

mysql_install_complete() {
  [[ -x "${mysql_install_dir}/bin/mysql" ]] || return 1
  [[ -x "${mysql_install_dir}/bin/mysqld" ]] || return 1
  [[ -d "${mysql_data_dir}/mysql" ]] || return 1
  [[ -f "$(mysql_service_file_path)" ]] || return 1
}

cleanup_partial_mysql_install() {
  if [[ -e "${mysql_install_dir}" ]] || directory_has_entries "${mysql_data_dir}"; then
    if [[ ! -d "${mysql_data_dir}/mysql" ]]; then
      warn "An incomplete MySQL installation was found; clean it before retrying: ${mysql_install_dir} / ${mysql_data_dir}"
      rm -rf "${mysql_install_dir}" "${mysql_data_dir}"
      return 0
    fi
    die "MySQL directories exist but installation is incomplete; inspect them first: ${mysql_install_dir} / ${mysql_data_dir}"
  fi
}

install_mysql() {
  if mysql_install_complete; then
    local detected
    detected="$(${mysql_install_dir}/bin/mysqld --version 2>/dev/null | extract_semver || true)"
    if should_skip_completed_install MySQL "${mysql_install_dir}" "${mysql_ver}" "${detected}"; then
      warn "MySQL is already installed: ${mysql_install_dir}"
      return 0
    fi
  fi
  cleanup_partial_mysql_install

  local url archive build_dir extracted mysql_password
  url="$(mysql_binary_url)" || die "No official MySQL binary package URL is configured for this architecture"
  mysql_password="${mysql_password:-$(random_password 20)}"

  download_src "${url}" "${url##*/}" "${mysql_sha256:-}"
  archive="${LNMP_SRC_DIR}/${url##*/}"
  build_dir="$(mktemp -d)"
  extract_archive "${archive}" "${build_dir}"
  extracted="$(find "${build_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

  ensure_user_group mysql mysql
  init_layout_dirs
  mkdir -p "$(dirname "${mysql_install_dir}")" "${mysql_data_dir}" "${mysql_log_dir}" "${pid_dir}" "${sock_dir}"
  mv "${extracted}" "${mysql_install_dir}"
  chown -R mysql:mysql "${mysql_install_dir}" "${mysql_data_dir}" "${mysql_log_dir}"
  ensure_libaio_compat

  cat > /etc/my.cnf <<EOF
[mysqld]
basedir=${mysql_install_dir}
datadir=${mysql_data_dir}
socket=${mysql_sock}
pid-file=${mysql_pid}
user=mysql
port=${mysql_port}
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
log-error=${mysql_log_dir}/error.log

[client]
socket=${mysql_sock}
EOF

  "${mysql_install_dir}/bin/mysqld" --initialize-insecure --user=mysql --basedir="${mysql_install_dir}" --datadir="${mysql_data_dir}"
  write_mysql_service
  link_mysql_cli_commands
  systemctl_reload_or_restart mysqld
  sleep 3
  "${mysql_install_dir}/bin/mysql" -uroot -S "${mysql_sock}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${mysql_password}'; FLUSH PRIVILEGES;"
  write_component_version_marker "${mysql_install_dir}" "${mysql_ver}"
  rm -rf "${build_dir}"
}

link_mysql_cli_commands() {
  local bin
  for bin in mysql mysqladmin mysqldump mysqlshow; do
    link_executable_to_bin "${mysql_install_dir}/bin/${bin}" "${bin}"
  done
}

write_mysql_service() {
  cat > "$(mysql_service_file_path)" <<EOF
[Unit]
Description=MySQL Server
After=network.target

[Service]
Type=forking
User=mysql
Group=mysql
ExecStart=${mysql_install_dir}/support-files/mysql.server start
ExecStop=${mysql_install_dir}/support-files/mysql.server stop
PIDFile=${mysql_pid}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}
