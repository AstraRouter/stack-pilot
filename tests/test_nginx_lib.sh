#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/nginx.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

LNMP_SYSTEMD_UNIT_DIR="${tmp_dir}/systemd"
nginx_install_dir="${tmp_dir}/nginx"
nginx_pid="${tmp_dir}/nginx.pid"
mkdir -p "${nginx_install_dir}/sbin"

write_nginx_service
unit="${LNMP_SYSTEMD_UNIT_DIR}/nginx.service"

grep -q '^Type=simple$' "${unit}" || fail "Nginx unit should use Type=simple"
grep -q 'nginx -g "daemon off;"$' "${unit}" || fail "Nginx should run in foreground under systemd"
grep -q '^ExecReload=/bin/kill -HUP \$MAINPID$' "${unit}" || fail "Nginx reload should signal systemd main PID"
grep -q '^ExecStop=/bin/kill -QUIT \$MAINPID$' "${unit}" || fail "Nginx stop should signal systemd main PID"
if grep -q '^PIDFile=' "${unit}"; then fail "foreground Nginx unit must not depend on PIDFile"; fi
grep -q '^Restart=on-failure$' "${unit}" || fail "Nginx unit should restart after unexpected failure"

echo "PASS: nginx service helpers"
