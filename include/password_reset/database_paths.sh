#!/usr/bin/env bash

database_reset_binary() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s/bin/mysqld' "${mysql_install_dir}" ;;
    mariadb)
      if [[ -x "${mariadb_install_dir}/bin/mariadbd" ]]; then
        printf '%s/bin/mariadbd' "${mariadb_install_dir}"
      else
        printf '%s/bin/mysqld' "${mariadb_install_dir}"
      fi
      ;;
    *) return 1 ;;
  esac
}

database_client_binary() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s/bin/mysql' "${mysql_install_dir}" ;;
    mariadb)
      if [[ -x "${mariadb_install_dir}/bin/mariadb" ]]; then
        printf '%s/bin/mariadb' "${mariadb_install_dir}"
      else
        printf '%s/bin/mysql' "${mariadb_install_dir}"
      fi
      ;;
    *) return 1 ;;
  esac
}

database_service_name() {
  local engine="$1"
  case "${engine}" in
    mysql) printf 'mysqld' ;;
    mariadb) printf 'mariadb' ;;
    *) return 1 ;;
  esac
}

database_socket_path() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s' "${mysql_sock}" ;;
    mariadb) printf '%s' "${mariadb_sock}" ;;
    *) return 1 ;;
  esac
}

database_pid_path() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s' "${mysql_pid}" ;;
    mariadb) printf '%s' "${mariadb_pid}" ;;
    *) return 1 ;;
  esac
}

database_install_dir() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s' "${mysql_install_dir}" ;;
    mariadb) printf '%s' "${mariadb_install_dir}" ;;
    *) return 1 ;;
  esac
}

database_data_dir() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s' "${mysql_data_dir}" ;;
    mariadb) printf '%s' "${mariadb_data_dir}" ;;
    *) return 1 ;;
  esac
}

database_reset_log_file() {
  local engine="$1"
  case "${engine}" in
    mysql) printf '%s/password-reset.log' "${mysql_log_dir}" ;;
    mariadb) printf '%s/password-reset.log' "${mariadb_log_dir}" ;;
    *) return 1 ;;
  esac
}
