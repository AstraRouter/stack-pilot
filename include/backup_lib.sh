#!/usr/bin/env bash

backup_timestamp() { date '+%Y%m%d-%H%M%S'; }

publish_backup_file() {
  local partial="$1" final="$2"
  [[ -s "${partial}" ]] || { rm -f "${partial}"; return 1; }
  mv "${partial}" "${final}"
}

backup_web() {
  local final partial
  [[ -d "${wwwroot_dir}" ]] || { warn "Web root does not exist: ${wwwroot_dir}"; return 1; }
  mkdir -p "${backup_dir}"
  final="${backup_dir}/wwwroot-$(backup_timestamp).tar.gz"
  partial="${final}.part"
  if LC_ALL=C tar czf "${partial}" -C "$(dirname "${wwwroot_dir}")" "$(basename "${wwwroot_dir}")"; then
    publish_backup_file "${partial}" "${final}" || die "The website backup is empty: ${final}"
  else
    rm -f "${partial}"
    return 1
  fi
  printf '%s' "${final}"
}

write_database_client_config() {
  local file="$1" password="$2" socket="$3"
  {
    printf '[client]\nuser=root\n'
    printf 'password=%s\n' "${password}"
    printf 'socket=%s\n' "${socket}"
  } > "${file}"
  chmod 600 "${file}"
}

backup_database_with() {
  local label="$1" dump_bin="$2" password="$3" socket="$4" output_prefix="$5"
  local credentials final partial
  [[ -x "${dump_bin}" ]] || { warn "The ${label} backup command was not found: ${dump_bin}"; return 1; }
  mkdir -p "${backup_dir}"
  credentials="$(mktemp)"
  final="${backup_dir}/${output_prefix}-$(backup_timestamp).sql"
  partial="${final}.part"
  write_database_client_config "${credentials}" "${password}" "${socket}"
  if "${dump_bin}" --defaults-extra-file="${credentials}" --all-databases > "${partial}" && publish_backup_file "${partial}" "${final}"; then
    rm -f "${credentials}"
    printf '%s' "${final}"
    return 0
  fi
  rm -f "${credentials}" "${partial}"
  warn "The ${label} backup failed; the incomplete file was not published"
  return 1
}

backup_mysql() {
  if [[ -x "${mysql_install_dir}/bin/mysqldump" ]]; then
    backup_database_with MySQL "${mysql_install_dir}/bin/mysqldump" "${mysql_password}" "${mysql_sock}" mysql-all
  elif [[ -x "${mariadb_install_dir}/bin/mariadb-dump" ]]; then
    backup_database_with MariaDB "${mariadb_install_dir}/bin/mariadb-dump" "${mariadb_password}" "${mariadb_sock}" mariadb-all
  else
    warn "mysqldump or mariadb-dump was not found"
    return 1
  fi
}

backup_redis() {
  local cli final partial
  cli="${redis_install_dir}/bin/redis-cli"
  [[ -x "${cli}" ]] || { warn "redis-cli was not found: ${cli}"; return 1; }
  [[ -d "${redis_data_dir}" ]] || { warn "Redis data directory does not exist: ${redis_data_dir}"; return 1; }
  REDISCLI_AUTH="${redis_password:-}" "${cli}" -h "${redis_bind:-127.0.0.1}" -p "${redis_port:-6379}" SAVE >/dev/null
  mkdir -p "${backup_dir}"
  final="${backup_dir}/redis-$(backup_timestamp).tar.gz"
  partial="${final}.part"
  if LC_ALL=C tar czf "${partial}" -C "$(dirname "${redis_data_dir}")" "$(basename "${redis_data_dir}")"; then
    publish_backup_file "${partial}" "${final}" || die "The Redis backup is empty: ${final}"
  else
    rm -f "${partial}"
    return 1
  fi
  printf '%s' "${final}"
}

backup_dir_is_safe() {
  local path="${1%/}"
  [[ -n "${path}" && "${path}" == /* ]] || return 1
  [[ "${path}" != *'/../'* && "${path}" != */.. && "${path}" != *'/./'* ]] || return 1
  case "${path}" in
    /|/bin|/boot|/data|/dev|/etc|/home|/lib|/lib32|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/data/logs|/usr/local/data|/usr/local/services)
      return 1
      ;;
  esac
  (( ${#path} >= 6 ))
}

cleanup_backups() {
  local days="${backup_keep_days:-7}"
  [[ "${days}" =~ ^[0-9]+$ ]] || die "backup_keep_days must be a non-negative integer"
  [[ -n "${backup_dir:-}" && -d "${backup_dir}" ]] || return 0
  backup_dir_is_safe "${backup_dir}" || die "Refusing to clean an unsafe backup directory: ${backup_dir}"
  # Only ever remove backup artifacts we create, never arbitrary files, and never recurse.
  find "${backup_dir}" -maxdepth 1 -type f \
    \( -name '*.tar.gz' -o -name '*.sql' -o -name '*.part' \) \
    -mtime "+${days}" -delete
}
