#!/usr/bin/env bash
set -euo pipefail

# Restores overwrite live data, and the safety archives written along the way
# hold the same site content and database dumps as the backups themselves.
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_options
source "${ROOT_DIR}/include/backup_lib.sh"
source "${ROOT_DIR}/include/restore_lib.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./restore.sh"
    echo "Run without parameters and follow the menu."
    exit 0
    ;;
  "") ;;
  *) warn "restore.sh does not accept operation arguments; opening the interactive menu." ;;
esac

choose_backup_artifact() {
  local prompt="$1" pattern="$2"
  local file entries=()
  while IFS= read -r file; do
    [[ -n "${file}" ]] && entries+=("${file}|$(basename "${file}")")
  done < <(backup_artifacts "${pattern}")
  ((${#entries[@]} > 0)) || { warn "No matching backups were found in ${backup_dir}"; return 1; }
  prompt_select "${prompt}" "$(entry_value "${entries[0]}")" "${entries[@]}"
}

# Nothing is overwritten until the operator has seen the exact file and target.
confirm_restore() {
  local what="$1" source_file="$2" target="$3"
  echo
  warn "About to restore ${what}."
  echo "  From: ${source_file}"
  echo "  Onto: ${target}"
  warn "The current contents are archived first, but this replaces live data."
  [[ "$(prompt_yes_no "Continue with the restore" "n")" == "y" ]] ||
    die "Cancelled; nothing was changed"
}

restore_website() {
  local archive
  require_root
  archive="$(choose_backup_artifact "Select a website backup" 'wwwroot-*.tar.gz')" || return 1
  confirm_restore "the website directory" "${archive}" "${wwwroot_dir}"
  restore_web_archive "${archive}"
}

restore_one_site() {
  local archive
  require_root
  archive="$(choose_backup_artifact "Select a site backup" 'site-*.tar.gz')" || return 1
  confirm_restore "a single site" "${archive}" "${wwwroot_dir}"
  restore_web_archive "${archive}"
}

restore_database() {
  local dump
  require_root
  dump="$(choose_backup_artifact "Select a database dump" '*-all-*.sql')" || return 1
  confirm_restore "all databases" "${dump}" "the running database server"
  restore_database_dump "${dump}"
}

restore_redis() {
  local archive
  require_root
  archive="$(choose_backup_artifact "Select a Redis backup" 'redis-*.tar.gz')" || return 1
  confirm_restore "the Redis data directory" "${archive}" "${redis_data_dir}"
  restore_redis_archive "${archive}"
}

list_available_backups() {
  local file
  echo
  echo "Backups in ${backup_dir}:"
  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    printf '  %s  %s\n' "$(du -h "${file}" 2>/dev/null | awk '{print $1}')" "$(basename "${file}")"
  done < <(backup_artifacts '*.tar.gz'; backup_artifacts '*.sql')
}

while :; do
  print_header
  choice="$(prompt_select "Select what to restore" "1" \
    "1|List available backups" \
    "2|Website directory (all sites)" \
    "3|One site" \
    "4|All MySQL/MariaDB databases" \
    "5|Redis data directory" \
    "6|Exit")"
  case "${choice}" in
    1) run_menu_action "Listing backups" list_available_backups ;;
    2) run_menu_action "Restoring the website directory" restore_website ;;
    3) run_menu_action "Restoring the site" restore_one_site ;;
    4) run_menu_action "Restoring the databases" restore_database ;;
    5) run_menu_action "Restoring Redis" restore_redis ;;
    6) exit 0 ;;
  esac
  pause_for_menu
done
