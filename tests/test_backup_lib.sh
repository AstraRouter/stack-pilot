#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/backup_lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
backup_dir="${tmp_dir}/backups"
fake_dump="${tmp_dir}/mysqldump"
args_file="${tmp_dir}/args"
cat > "${fake_dump}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${args_file}"
printf '%s\n' 'CREATE DATABASE example;'
EOF
chmod +x "${fake_dump}"

result="$(backup_database_with MySQL "${fake_dump}" 'secret value' '/tmp/mysql.sock' mysql-all)"
[[ -s "${result}" ]] || fail "successful database backup should be published"
grep -q -- '--defaults-extra-file=' "${args_file}" || fail "database dump should use a protected option file"
if grep -q 'secret value' "${args_file}"; then fail "database password leaked into process arguments"; fi
if find "${backup_dir}" -name '*.part' | grep -q .; then fail "successful backup left a partial file"; fi

failing_dump="${tmp_dir}/failing-dump"
cat > "${failing_dump}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${failing_dump}"
if backup_database_with MySQL "${failing_dump}" secret '/tmp/mysql.sock' failed >/dev/null 2>&1; then
  fail "failed database dump reported success"
fi
if find "${backup_dir}" -name 'failed*' | grep -q .; then fail "failed dump published a backup file"; fi

wwwroot_dir="${tmp_dir}/wwwroot"
mkdir -p "${wwwroot_dir}"
printf 'ok\n' > "${wwwroot_dir}/index.html"
web_result="$(backup_web)"
[[ -s "${web_result}" ]] || fail "web backup should be published atomically"

backup_keep_days=invalid
if (cleanup_backups >/dev/null 2>&1); then fail "invalid retention days should be rejected"; fi

echo "PASS: backup helpers"
