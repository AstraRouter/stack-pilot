#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/mysql.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mysql_install_dir="${tmp_dir}/services/mysql"
mysql_data_dir="${tmp_dir}/data/mysql"
MYSQL_SERVICE_FILE_OVERRIDE="${tmp_dir}/mysqld.service"

mkdir -p "${mysql_data_dir}"
cleanup_partial_mysql_install
[[ -d "${mysql_data_dir}" ]] || fail "empty precreated MySQL data dir should not be treated as partial install"

mkdir -p "${mysql_install_dir}/bin" "${mysql_data_dir}"
touch "${mysql_install_dir}/bin/mysql" "${mysql_install_dir}/bin/mysqld"
chmod +x "${mysql_install_dir}/bin/mysql" "${mysql_install_dir}/bin/mysqld"
if mysql_install_complete; then
  fail "partial MySQL install should not be complete"
fi
cleanup_partial_mysql_install
[[ ! -e "${mysql_install_dir}" ]] || fail "partial MySQL install dir should be cleaned"
[[ ! -e "${mysql_data_dir}" ]] || fail "partial MySQL data dir should be cleaned"

mkdir -p "${mysql_install_dir}/bin" "${mysql_data_dir}/mysql"
touch "${mysql_install_dir}/bin/mysql" "${mysql_install_dir}/bin/mysqld" "${MYSQL_SERVICE_FILE_OVERRIDE}"
chmod +x "${mysql_install_dir}/bin/mysql" "${mysql_install_dir}/bin/mysqld"
mysql_install_complete || fail "initialized MySQL install should be complete"

libaio_dir="${tmp_dir}/lib"
mkdir -p "${libaio_dir}"
touch "${libaio_dir}/libaio.so.1t64"
LIBAIO_COMPAT_SOURCE_OVERRIDE="${libaio_dir}/libaio.so.1t64"
LIBAIO_COMPAT_TARGET_OVERRIDE="${libaio_dir}/libaio.so.1"
ensure_libaio_compat
[[ -L "${libaio_dir}/libaio.so.1" ]] || fail "libaio compatibility symlink should be created"

echo "PASS: mysql helpers"
