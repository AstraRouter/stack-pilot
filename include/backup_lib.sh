#!/usr/bin/env bash

backup_timestamp() { date '+%Y%m%d-%H%M%S'; }

publish_backup_file() {
  local partial="$1" final="$2"
  [[ -s "${partial}" ]] || { rm -f "${partial}"; return 1; }
  mv "${partial}" "${final}"
  # Dumps and site archives stay readable only by root even if the caller's
  # umask is permissive.
  protect_private_file "${final}"
}

backup_web() {
  local final partial
  [[ -d "${wwwroot_dir}" ]] || { warn "Web root does not exist: ${wwwroot_dir}"; return 1; }
  ensure_private_dir "${backup_dir}"
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
    printf 'password="%s"\n' "${password}"
    printf 'socket=%s\n' "${socket}"
  } > "${file}"
  chmod 600 "${file}"
}

# mysqldump defaults leave --routines and --events off, so a plain
# --all-databases dump silently omits every stored procedure, function, and
# scheduled event, and only reveals the gap on restore. --single-transaction
# takes a consistent InnoDB snapshot in one transaction instead of locking each
# database in turn, which would block writes on a live site for the whole dump;
# it also implies --lock-tables=false. --quick streams rows instead of buffering
# a whole table in memory.
database_dump_options() {
  printf '%s\n' \
    --routines \
    --events \
    --triggers \
    --single-transaction \
    --quick \
    --default-character-set=utf8mb4
}

backup_database_with() {
  local label="$1" dump_bin="$2" password="$3" socket="$4" output_prefix="$5"
  local credentials final partial option
  local dump_options=()
  [[ -x "${dump_bin}" ]] || { warn "The ${label} backup command was not found: ${dump_bin}"; return 1; }
  ensure_private_dir "${backup_dir}"
  credentials="$(mktemp)"
  # Removed explicitly on both paths below rather than through a RETURN trap: a
  # RETURN trap stays installed after this function returns and fires again when
  # backup_mysql returns, where ${credentials} is out of scope. Under set -u that
  # aborted the wrapper *after* a good dump had already been published, so the
  # menu reported a skipped backup while the .sql file sat in the backup dir.
  final="${backup_dir}/${output_prefix}-$(backup_timestamp).sql"
  partial="${final}.part"
  while IFS= read -r option; do
    dump_options+=("${option}")
  done < <(database_dump_options)
  write_database_client_config "${credentials}" "${password}" "${socket}"
  if "${dump_bin}" --defaults-extra-file="${credentials}" "${dump_options[@]}" --all-databases > "${partial}" && publish_backup_file "${partial}" "${final}"; then
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

redis_cli_call() {
  local cli="$1"
  shift
  REDISCLI_AUTH="${redis_password:-}" "${cli}" -h "${redis_bind:-127.0.0.1}" -p "${redis_port:-6379}" "$@"
}

# SAVE writes the whole dataset from the main thread, so every client is blocked
# for as long as it takes — seconds to minutes on a large dataset. BGSAVE forks
# and returns immediately, so the completion is detected by watching LASTSAVE
# change. A save that cannot be started or does not finish is reported and the
# archive is still written from whatever snapshot is already on disk, because a
# slightly stale backup is more useful than no backup.
redis_background_save() {
  local cli="$1"
  local attempts="${LNMP_REDIS_BGSAVE_ATTEMPTS:-300}"
  local before after i
  before="$(redis_cli_call "${cli}" LASTSAVE 2>/dev/null | tr -dc '0-9')"
  if ! redis_cli_call "${cli}" BGSAVE >/dev/null 2>&1; then
    warn "Redis did not accept BGSAVE; the archive will contain the snapshot already on disk"
    return 1
  fi
  for ((i = 0; i < attempts; i++)); do
    after="$(redis_cli_call "${cli}" LASTSAVE 2>/dev/null | tr -dc '0-9')"
    [[ -n "${after}" && "${after}" != "${before}" ]] && return 0
    sleep 1
  done
  warn "The Redis background save did not finish within ${attempts}s; the archive may not include the newest writes"
  return 1
}

backup_redis() {
  local cli final partial
  cli="${redis_install_dir}/bin/redis-cli"
  [[ -x "${cli}" ]] || { warn "redis-cli was not found: ${cli}"; return 1; }
  [[ -d "${redis_data_dir}" ]] || { warn "Redis data directory does not exist: ${redis_data_dir}"; return 1; }
  redis_background_save "${cli}" || true
  ensure_private_dir "${backup_dir}"
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

# Sites are the immediate sub-directories of the web root. A server hosting
# dozens of sites should not have to archive all of them to back up one.
list_backup_sites() {
  local entry
  [[ -d "${wwwroot_dir}" ]] || return 0
  for entry in "${wwwroot_dir}"/*/; do
    entry="${entry%/}"
    [[ -d "${entry}" ]] || continue
    printf '%s\n' "$(basename "${entry}")"
  done
}

backup_site() {
  local site="${1:-}" final partial root
  [[ -n "${site}" ]] || { warn "No site was selected"; return 1; }
  # The name becomes a path component and part of the archive file name.
  [[ "${site}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    { warn "Invalid site directory name: ${site}"; return 1; }
  root="${wwwroot_dir}/${site}"
  [[ -d "${root}" ]] || { warn "Site directory does not exist: ${root}"; return 1; }
  ensure_private_dir "${backup_dir}"
  final="${backup_dir}/site-${site}-$(backup_timestamp).tar.gz"
  partial="${final}.part"
  if LC_ALL=C tar czf "${partial}" -C "${wwwroot_dir}" "${site}"; then
    publish_backup_file "${partial}" "${final}" || { warn "The ${site} backup is empty"; return 1; }
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
  [[ "${days}" =~ ^0*([0-9]{1,5})$ ]] || die "backup_keep_days must be an integer from 0 through 99999"
  days="$((10#${BASH_REMATCH[1]}))"
  [[ -n "${backup_dir:-}" && -d "${backup_dir}" ]] || return 0
  backup_dir_is_safe "${backup_dir}" || die "Refusing to clean an unsafe backup directory: ${backup_dir}"
  # 0 disables retention rather than meaning "keep nothing". Reading it as a
  # zero-day retention would delete every backup on the host, which is never
  # what an unset or defaulted value is meant to express.
  if ((days == 0)); then
    info "backup_keep_days is 0, so retention is disabled and no backups were removed"
    return 0
  fi
  # -mtime +N matches files strictly older than N+1 days, so a 7-day retention
  # would actually keep 8. Minutes express the boundary exactly.
  # Only ever remove backup artifacts we create, never arbitrary files, and never recurse.
  find "${backup_dir}" -maxdepth 1 -type f \
    \( -name '*.tar.gz' -o -name '*.sql' -o -name '*.part' \) \
    -mmin "+$((days * 1440))" -delete
}
