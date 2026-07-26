#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_options
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/logrotate.sh"
source "${ROOT_DIR}/include/fail2ban.sh"
source "${ROOT_DIR}/include/vhost_lib.sh"
source "${ROOT_DIR}/include/status_report.sh"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./status.sh"
    echo "Print component versions, service state, ports, certificates, and disk usage."
    exit 0
    ;;
  "") ;;
  *) warn "status.sh does not accept arguments; printing the full report." ;;
esac

print_status_report
