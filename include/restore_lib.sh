#!/usr/bin/env bash

# Restoring is the other half of backing up. Without it the archives under
# ${backup_dir} are only useful to someone who already knows the exact layout
# they were created with, and every recovery becomes a hand-written tar or mysql
# command typed under pressure.

restore_service_control() {
  local action="$1" service="$2"
  [[ -n "${service}" && "${LNMP_RESTORE_SKIP_SERVICE_CONTROL:-0}" != "1" ]] || return 0
  if command_exists systemctl; then
    systemctl "${action}" "${service}"
  else
    service "${service}" "${action}"
  fi
}

# Newest first, so the default choice is the most recent backup.
backup_artifacts() {
  local pattern="$1"
  [[ -n "${backup_dir:-}" && -d "${backup_dir}" ]] || return 0
  find "${backup_dir}" -maxdepth 1 -type f -name "${pattern}" 2>/dev/null | sort -r
}

# A tar archive can name absolute paths or ".." components, which would write
# outside the directory being restored into. GNU tar strips a leading slash but
# not every implementation refuses traversal, so the member list is inspected
# before anything is extracted.
assert_archive_is_relative() {
  local archive="$1" entry listing status=0 verdict=0
  # The listing goes to a file rather than through a pipe so tar's exit status
  # is visible: a truncated or corrupt archive lists nothing, and a loop over an
  # empty stream would otherwise report it as safe and go on to extract it.
  # A file also keeps the memory cost flat for an archive with a million members.
  # There is a single exit path so the file can be removed without a RETURN
  # trap, which would stay installed and fire again in the caller.
  listing="$(mktemp)"
  LC_ALL=C tar tzf "${archive}" > "${listing}" 2>/dev/null || status=$?
  if ((status != 0)); then
    warn "Refusing to extract ${archive}: it could not be read as a gzip tar archive"
    verdict=1
  elif [[ ! -s "${listing}" ]]; then
    warn "Refusing to extract ${archive}: it contains no files"
    verdict=1
  else
    while IFS= read -r entry; do
      if [[ "${entry}" == /* ]]; then
        warn "Refusing to extract ${archive}: it contains the absolute path ${entry}"
        verdict=1
        break
      fi
      case "/${entry}" in
        */../*|*/..)
          warn "Refusing to extract ${archive}: it contains the traversing path ${entry}"
          verdict=1
          break
          ;;
      esac
    done < "${listing}"
  fi
  rm -f "${listing}"
  return "${verdict}"
}

# The top-level names an archive would create under a destination directory.
# Ownership is applied to exactly these, never to the destination itself: a
# single-site restore into the web root must not rewrite the ownership of every
# other site on the host.
restored_top_level_paths() {
  local archive="$1" destination="${2%/}" entry
  LC_ALL=C tar tzf "${archive}" 2>/dev/null |
    while IFS= read -r entry; do
      entry="${entry#./}"
      entry="${entry%%/*}"
      [[ -n "${entry}" && "${entry}" != "." ]] || continue
      printf '%s/%s\n' "${destination}" "${entry}"
    done | awk '!seen[$0]++'
}

validate_restore_source() {
  local file="$1"
  [[ -n "${file}" ]] || { warn "No backup file was selected"; return 1; }
  [[ -f "${file}" && -s "${file}" ]] || { warn "Backup file not found or empty: ${file}"; return 1; }
  # Only ever read from the configured backup directory.
  [[ "${file}" == "${backup_dir%/}/"* ]] ||
    { warn "Refusing to restore from outside ${backup_dir}: ${file}"; return 1; }
}

# A restore overwrites live data, so the current state is archived first. The
# way back is then an ordinary restore of that archive.
snapshot_before_restore() {
  local label="$1" path="$2" archive
  [[ -e "${path}" ]] || return 0
  ensure_private_dir "${backup_dir}"
  archive="${backup_dir}/pre-restore-${label}-$(backup_timestamp).tar.gz"
  if ! LC_ALL=C tar czf "${archive}" -C "$(dirname "${path}")" "$(basename "${path}")"; then
    rm -f "${archive}"
    warn "Could not archive the current ${label} before restoring"
    return 1
  fi
  protect_private_file "${archive}"
  ok "Current ${label} archived before the restore: ${archive}"
}

# wwwroot-*.tar.gz holds the web root itself, so it extracts into the parent.
# site-<name>-*.tar.gz holds one site directory and extracts into the web root.
restore_web_archive() {
  local archive="$1" destination
  validate_restore_source "${archive}" || return 1
  assert_archive_is_relative "${archive}" || return 1
  case "$(basename "${archive}")" in
    wwwroot-*) destination="$(dirname "${wwwroot_dir}")" ;;
    site-*) destination="${wwwroot_dir}" ;;
    pre-restore-wwwroot-*) destination="$(dirname "${wwwroot_dir}")" ;;
    *) warn "Unrecognised website archive name: $(basename "${archive}")"; return 1 ;;
  esac
  snapshot_before_restore wwwroot "${wwwroot_dir}" || return 1
  mkdir -p "${destination}"
  LC_ALL=C tar xzf "${archive}" -C "${destination}" || { warn "Extraction failed: ${archive}"; return 1; }
  if id "${user:-www}" >/dev/null 2>&1; then
    while IFS= read -r restored; do
      [[ -e "${restored}" ]] || continue
      chown -R "${user:-www}:${group:-www}" "${restored}" 2>/dev/null ||
        warn "Restored files in ${restored} could not be handed back to ${user:-www}:${group:-www}"
    done < <(restored_top_level_paths "${archive}" "${destination}")
  fi
  ok "Website restored from ${archive}"
}

restore_database_with() {
  local label="$1" client="$2" password="$3" socket="$4" dump="$5"
  local credentials status=0
  [[ -x "${client}" ]] || { warn "The ${label} client was not found: ${client}"; return 1; }
  validate_restore_source "${dump}" || return 1
  credentials="$(mktemp)"
  # Removed explicitly, not through a RETURN trap: such a trap stays installed
  # after this function returns and fires again in the caller, where the local
  # it names is gone.
  # The password goes through a mode-600 defaults file, never the command line.
  write_database_client_config "${credentials}" "${password}" "${socket}"
  if "${client}" --defaults-extra-file="${credentials}" < "${dump}"; then
    # An --all-databases dump replaces the mysql schema, so in-memory grants are
    # stale until they are reloaded.
    "${client}" --defaults-extra-file="${credentials}" -e "FLUSH PRIVILEGES" >/dev/null 2>&1 || true
    ok "${label} restored from ${dump}"
  else
    warn "The ${label} restore failed; the server may hold a partially applied dump"
    status=1
  fi
  rm -f "${credentials}"
  return "${status}"
}

restore_database_dump() {
  local dump="$1"
  if [[ -x "${mysql_install_dir}/bin/mysql" ]]; then
    restore_database_with MySQL "${mysql_install_dir}/bin/mysql" "${mysql_password}" "${mysql_sock}" "${dump}"
  elif [[ -x "${mariadb_install_dir}/bin/mariadb" ]]; then
    restore_database_with MariaDB "${mariadb_install_dir}/bin/mariadb" "${mariadb_password}" "${mariadb_sock}" "${dump}"
  elif [[ -x "${mariadb_install_dir}/bin/mysql" ]]; then
    restore_database_with MariaDB "${mariadb_install_dir}/bin/mysql" "${mariadb_password}" "${mariadb_sock}" "${dump}"
  else
    warn "No MySQL or MariaDB client was found; cannot restore ${dump}"
    return 1
  fi
}

# Redis loads its dump only at startup, so the file has to be replaced while the
# server is stopped. Writing it underneath a running server would be discarded
# by the next background save.
restore_redis_archive() {
  local archive="$1" parent
  validate_restore_source "${archive}" || return 1
  assert_archive_is_relative "${archive}" || return 1
  [[ -n "${redis_data_dir:-}" ]] || { warn "redis_data_dir is not configured"; return 1; }
  snapshot_before_restore redis "${redis_data_dir}" || return 1
  parent="$(dirname "${redis_data_dir}")"
  restore_service_control stop redis-server >/dev/null 2>&1 || true
  rm -rf -- "${redis_data_dir}"
  mkdir -p "${parent}"
  if ! LC_ALL=C tar xzf "${archive}" -C "${parent}"; then
    warn "Extraction failed: ${archive}. Redis is stopped and its data directory is incomplete"
    return 1
  fi
  chown -R redis:redis "${redis_data_dir}" 2>/dev/null || true
  restore_service_control start redis-server || { warn "Redis did not start after the restore"; return 1; }
  ok "Redis restored from ${archive}"
}
