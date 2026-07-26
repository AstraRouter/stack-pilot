#!/usr/bin/env bash
set -euo pipefail

# Backups contain full database dumps and site data — keep them private
# (new files 0600, new directories 0700).
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_options
source "${ROOT_DIR}/include/backup_lib.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./backup.sh"
    echo "Run without parameters and follow the menu."
    exit 0
    ;;
  "") ;;
  *) warn "backup.sh does not accept operation arguments; opening the interactive menu." ;;
esac

run_backup_step() {
  local label="$1"; shift
  local artifact
  if artifact="$("$@")"; then
    ok "${label} backup written: ${artifact}"
  else
    warn "${label} backup was skipped (nothing to back up, or it failed)"
  fi
}

choose_site_to_back_up() {
  local site entries=()
  while IFS= read -r site; do
    [[ -n "${site}" ]] && entries+=("${site}|${site}")
  done < <(list_backup_sites)
  ((${#entries[@]} > 0)) || { warn "No site directories were found under ${wwwroot_dir}"; return 1; }
  prompt_select "Select a site" "$(entry_value "${entries[0]}")" "${entries[@]}"
}

backup_single_site() {
  local site
  site="$(choose_site_to_back_up)" || return 1
  run_backup_step "Site ${site}" backup_site "${site}"
}

while :; do
  print_header
  choice="$(prompt_select "Select backup content" "1" \
    "1|Website directory (all sites)" \
    "2|One site" \
    "3|All MySQL/MariaDB databases" \
    "4|Redis data directory" \
    "5|Everything" \
    "6|Remove expired backups" \
    "7|Exit")"
  case "${choice}" in
    1) run_backup_step "Website" backup_web ;;
    2) run_menu_action "Backing up the site" backup_single_site ;;
    3) run_backup_step "Database" backup_mysql ;;
    4) run_backup_step "Redis" backup_redis ;;
    5)
      run_backup_step "Website" backup_web
      run_backup_step "Database" backup_mysql
      run_backup_step "Redis" backup_redis
      ;;
    6) cleanup_backups || warn "Expired-backup cleanup did not complete" ;;
    7) exit 0 ;;
  esac
  pause_for_menu
done
