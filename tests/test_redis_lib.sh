#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/redis.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_eq "" "$(redis_requirepass_line "")" "empty Redis password should not write requirepass"
redis_requirepass_line "" >/dev/null || fail "empty Redis password helper should still return success"
assert_eq "requirepass secret123" "$(redis_requirepass_line "secret123")" "Redis password should write requirepass"
assert_eq "" "$(redis_cli_auth_args "")" "empty Redis password should not pass auth args"
redis_cli_auth_args "" >/dev/null || fail "empty Redis auth args helper should still return success"
assert_eq "-a secret123" "$(redis_cli_auth_args "secret123")" "Redis password should pass redis-cli auth args"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
redis_install_dir="${tmp_dir}/redis"
redis_data_dir="${tmp_dir}/data"
REDIS_SERVICE_FILE_OVERRIDE="${tmp_dir}/redis-server.service"

mkdir -p "${redis_data_dir}"
cleanup_partial_redis_install
[[ -d "${redis_data_dir}" ]] || fail "empty precreated Redis data dir should not be treated as partial install"

mkdir -p "${redis_install_dir}/bin" "${redis_data_dir}"
touch "${redis_install_dir}/bin/redis-server" "${redis_install_dir}/bin/redis-cli"
chmod +x "${redis_install_dir}/bin/redis-server" "${redis_install_dir}/bin/redis-cli"
if redis_install_complete; then
  fail "partial Redis install should not be complete without config and service"
fi

echo "PASS: redis helpers"
