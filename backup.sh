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

while :; do
  print_header
  choice="$(prompt_select "Select backup content" "1" \
    "1|Website directory" \
    "2|All MySQL/MariaDB databases" \
    "3|Redis data directory" \
    "4|Everything" \
    "5|Remove expired backups" \
    "6|Exit")"
  case "${choice}" in
    1) run_backup_step "Website" backup_web ;;
    2) run_backup_step "Database" backup_mysql ;;
    3) run_backup_step "Redis" backup_redis ;;
    4)
      run_backup_step "Website" backup_web
      run_backup_step "Database" backup_mysql
      run_backup_step "Redis" backup_redis
      ;;
    5) cleanup_backups || warn "Expired-backup cleanup did not complete" ;;
    6) exit 0 ;;
  esac
  echo
  read -r -p "Press Enter to return to the menu..." _ || true
done
