#!/usr/bin/env bash
set -euo pipefail

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
    1) backup_web ;;
    2) backup_mysql ;;
    3) backup_redis ;;
    4) backup_web; backup_mysql; backup_redis ;;
    5) cleanup_backups ;;
    6) exit 0 ;;
  esac
  ok "Backup operation completed: ${backup_dir}"
done
