#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/password_reset.sh"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

conf="${tmp_dir}/redis.conf"
cat > "${conf}" <<'EOF'
bind 127.0.0.1
port 6379
requirepass old-password
appendonly yes
EOF

reset_redis_config_password "${conf}" "new-password"
grep -q '^requirepass new-password$' "${conf}" || fail "Redis password should be replaced"
[[ "$(grep -c '^requirepass ' "${conf}")" == "1" ]] || fail "Redis config should contain one requirepass line"

reset_redis_config_password "${conf}" ""
if grep -q '^requirepass ' "${conf}"; then
  fail "Redis password should be removed when new password is empty"
fi

reset_redis_config_password "${conf}" "again"
grep -q '^requirepass again$' "${conf}" || fail "Redis password should be appended when missing"

assert_eq "'simple123'" "$(sql_quote_literal simple123)" "SQL quote should wrap simple values"
assert_eq "'a''b'" "$(sql_quote_literal "a'b")" "SQL quote should escape single quotes"

mysql_log_dir="${tmp_dir}/logs/mysql"
mariadb_log_dir="${tmp_dir}/logs/mariadb"
assert_eq "${mysql_log_dir}/password-reset.log" "$(database_reset_log_file mysql)" "MySQL reset log should live under mysql_log_dir"
assert_eq "${mariadb_log_dir}/password-reset.log" "$(database_reset_log_file mariadb)" "MariaDB reset log should live under mariadb_log_dir"

echo "PASS: password reset helpers"
