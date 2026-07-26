#!/usr/bin/env bash

mariadb_service_file_path() {
  printf '%s' "${MARIADB_SERVICE_FILE_OVERRIDE:-/etc/systemd/system/mariadb.service}"
}

mariadb_install_complete() {
  { [[ -x "${mariadb_install_dir}/bin/mariadb" ]] || [[ -x "${mariadb_install_dir}/bin/mysql" ]]; } || return 1
  [[ -d "${mariadb_data_dir}/mysql" ]] || return 1
  [[ -f "$(mariadb_service_file_path)" ]] || return 1
}

install_mariadb() {
  if mariadb_install_complete; then
    local detected version_bin
    version_bin="${mariadb_install_dir}/bin/mariadb"
    [[ -x "${version_bin}" ]] || version_bin="${mariadb_install_dir}/bin/mysql"
    detected="$(${version_bin} --version 2>/dev/null | extract_semver || true)"
    if should_skip_completed_install MariaDB "${mariadb_install_dir}" "${mariadb_ver}" "${detected}"; then
      warn "MariaDB is already installed: ${mariadb_install_dir}"
      return 0
    fi
  fi

  local url archive build_dir extracted mariadb_password
  url="$(mariadb_binary_url)" || die "No official MariaDB binary package URL is configured for this architecture ($(uname -m))"
  mariadb_password="${mariadb_password:-$(random_password 20)}"

  download_src "${url}" "${url##*/}" "${mariadb_sha256:-}"
  archive="${LNMP_SRC_DIR}/${url##*/}"
  build_dir="$(make_build_dir)"
  extract_archive "${archive}" "${build_dir}"
  extracted="$(find "${build_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

  ensure_user_group mysql mysql
  init_layout_dirs
  mkdir -p "$(dirname "${mariadb_install_dir}")" "${mariadb_data_dir}" "${mariadb_log_dir}" "${pid_dir}" "${sock_dir}"
  # mariadbd runs as mysql and removes its pid file on clean shutdown, so it
  # needs to create entries in both directories, not just write existing files.
  grant_runtime_dir_access "${pid_dir}" mysql
  grant_runtime_dir_access "${sock_dir}" mysql
  mv "${extracted}" "${mariadb_install_dir}"
  chown -R mysql:mysql "${mariadb_install_dir}" "${mariadb_data_dir}" "${mariadb_log_dir}"

  cat > /etc/my.cnf <<EOF
[mysqld]
basedir=${mariadb_install_dir}
datadir=${mariadb_data_dir}
socket=${mariadb_sock}
pid-file=${mariadb_pid}
user=mysql
port=${mariadb_port}
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
log-error=${mariadb_log_dir}/error.log

[client]
socket=${mariadb_sock}
EOF

  "${mariadb_install_dir}/scripts/mariadb-install-db" --user=mysql --basedir="${mariadb_install_dir}" --datadir="${mariadb_data_dir}"
  write_mariadb_service
  link_mariadb_cli_commands
  systemctl_reload_or_restart mariadb
  local mariadb_client="${mariadb_install_dir}/bin/mariadb"
  [[ -x "${mariadb_client}" ]] || mariadb_client="${mariadb_install_dir}/bin/mysql"
  wait_for_database_ready "${mariadb_client}" "${mariadb_sock}" \
    || die "MariaDB did not become ready on ${mariadb_sock}; inspect ${mariadb_log_dir}/error.log"
  printf "ALTER USER 'root'@'localhost' IDENTIFIED BY %s; FLUSH PRIVILEGES;\n" "$(sql_quote_literal "${mariadb_password}")" \
    | "${mariadb_client}" -uroot -S "${mariadb_sock}" \
    || die "Failed to set the MariaDB root password; once MariaDB is running set it with: ./reset-password.sh mariadb"
  verify_database_root_password "${mariadb_client}" "${mariadb_sock}" "${mariadb_password}" \
    || die "The MariaDB root password was set but does not authenticate. MariaDB 10.4+ creates root@localhost with the unix_socket plugin; reset it with: ./reset-password.sh mariadb"
  write_component_version_marker "${mariadb_install_dir}" "${mariadb_ver}"
  rm -rf "${build_dir}"
}

link_mariadb_cli_commands() {
  local bin
  for bin in mariadb mariadb-admin mariadb-dump mysql mysqladmin mysqldump mysqlshow; do
    link_executable_to_bin "${mariadb_install_dir}/bin/${bin}" "${bin}"
  done
}

write_mariadb_service() {
  cat > "$(mariadb_service_file_path)" <<EOF
[Unit]
Description=MariaDB Server
After=network.target

[Service]
Type=forking
User=mysql
Group=mysql
ExecStart=${mariadb_install_dir}/support-files/mysql.server start
ExecStop=${mariadb_install_dir}/support-files/mysql.server stop
PIDFile=${mariadb_pid}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}
