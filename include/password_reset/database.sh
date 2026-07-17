#!/usr/bin/env bash

sql_quote_literal() {
  local value="$1"
  value="$(printf '%s' "${value}" | sed "s/'/''/g")"
  printf "'%s'" "${value}"
}

prepare_database_reset_log_file() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  chown mysql:mysql "${file}" "$(dirname "${file}")" 2>/dev/null || true
}

wait_for_database_socket() {
  local client="$1"
  local socket="$2"
  local i
  for i in $(seq 1 60); do
    if [[ -S "${socket}" ]] && "${client}" -uroot -S "${socket}" -e "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

reset_database_root_password() {
  local engine="$1"
  local password="$2"
  local service mysqld client socket pid_file install_dir data_dir log_file reset_pid sql
  validate_password_or_random "${password}" 6 || die "The database password must be at least 6 characters and must not contain single quotes or backslashes"
  service="$(database_service_name "${engine}")" || die "Unknown database engine: ${engine}"
  mysqld="$(database_reset_binary "${engine}")"
  client="$(database_client_binary "${engine}")"
  socket="$(database_socket_path "${engine}")"
  pid_file="$(database_pid_path "${engine}").reset"
  install_dir="$(database_install_dir "${engine}")"
  data_dir="$(database_data_dir "${engine}")"
  log_file="$(database_reset_log_file "${engine}")"

  [[ -x "${mysqld}" ]] || die "Database server binary does not exist: ${mysqld}"
  [[ -x "${client}" ]] || die "Database client binary does not exist: ${client}"
  [[ -d "${data_dir}" ]] || die "Database data directory does not exist: ${data_dir}"

  systemctl stop "${service}" >/dev/null 2>&1 || true
  rm -f "${socket}" "${pid_file}"
  mkdir -p "$(dirname "${socket}")" "$(dirname "${pid_file}")" "$(dirname "${log_file}")"
  prepare_database_reset_log_file "${log_file}"

  "${mysqld}" \
    --no-defaults \
    --basedir="${install_dir}" \
    --datadir="${data_dir}" \
    --socket="${socket}" \
    --pid-file="${pid_file}" \
    --user=mysql \
    --skip-grant-tables \
    --skip-networking \
    --log-error="${log_file}" &
  reset_pid="$!"

  if ! wait_for_database_socket "${client}" "${socket}"; then
    kill "${reset_pid}" >/dev/null 2>&1 || true
    wait "${reset_pid}" >/dev/null 2>&1 || true
    systemctl start "${service}" >/dev/null 2>&1 || true
    die "The database could not start in temporary password-reset mode; inspect ${log_file}"
  fi

  sql="FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY $(sql_quote_literal "${password}"); FLUSH PRIVILEGES;"
  if ! "${client}" -uroot -S "${socket}" -e "${sql}"; then
    kill "${reset_pid}" >/dev/null 2>&1 || true
    wait "${reset_pid}" >/dev/null 2>&1 || true
    systemctl start "${service}" >/dev/null 2>&1 || true
    die "The database password could not be updated"
  fi

  kill "${reset_pid}" >/dev/null 2>&1 || true
  wait "${reset_pid}" >/dev/null 2>&1 || true
  rm -f "${socket}" "${pid_file}"
  systemctl start "${service}"
}
