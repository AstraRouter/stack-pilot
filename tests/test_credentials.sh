#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/backup_lib.sh"
source "${ROOT_DIR}/include/redis.sh"
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

# --- Redis password character set --------------------------------------------

validate_redis_password "" || fail "an empty Redis password should be allowed (authentication disabled)"
for good in "s3cret-value" "A1._~!@%^*+=:,/-" "$(random_password 20)"; do
  validate_redis_password "${good}" || fail "Redis password '${good}' should be accepted"
done

# Each of these silently corrupts redis.conf or the systemd EnvironmentFile.
while IFS= read -r bad; do
  if validate_redis_password "${bad}"; then
    fail "Redis password '${bad}' should be rejected"
  fi
done <<'BAD'
my pass
pass#comment
short
pass"quote
pass'quote
pass\backslash
pass$var
pass`cmd`
pass;extra
BAD
if validate_redis_password "$(printf 'line1\nrequirepass evil')"; then
  fail "a newline in a Redis password should be rejected"
fi

# --- Redis reset refuses to corrupt the config -------------------------------

redis_install_dir="${tmp_dir}/redis"
mkdir -p "${redis_install_dir}/etc"
redis_conf="${redis_install_dir}/etc/redis.conf"
printf 'bind 127.0.0.1\nport 6379\nrequirepass original-secret\n' > "${redis_conf}"
conf_before="$(cat "${redis_conf}")"

if ( reset_redis_password "bad password with spaces" ) >/dev/null 2>&1; then
  fail "resetting to an unquotable Redis password should fail"
fi
assert_eq "${conf_before}" "$(cat "${redis_conf}")" \
  "a rejected Redis password must leave redis.conf untouched"

# The config rewrite itself still works for an acceptable password.
reset_redis_config_password "${redis_conf}" "new-secret-value"
grep -q '^requirepass new-secret-value$' "${redis_conf}" || fail "the Redis password should be rewritten"
assert_eq "1" "$(grep -c '^requirepass' "${redis_conf}")" "exactly one requirepass line should remain"

reset_redis_config_password "${redis_conf}" ""
if grep -q 'requirepass' "${redis_conf}"; then fail "an empty password should remove requirepass"; fi

# --- database client config ---------------------------------------------------

client_config="${tmp_dir}/client.cnf"
write_database_client_config "${client_config}" 'pa#ss' '/tmp/mysql.sock'
# An unquoted '#' starts a comment in a MySQL option file, which silently
# truncates the password and makes the backup authenticate as an empty user.
grep -q '^password="pa#ss"$' "${client_config}" ||
  fail "the client config should quote the password: $(cat "${client_config}")"
config_mode="$(stat -c '%a' "${client_config}" 2>/dev/null || stat -f '%Lp' "${client_config}")"
assert_eq "600" "${config_mode}" "the client config must not be readable by other accounts"

# --- root password verification ----------------------------------------------

fake_client="${tmp_dir}/fake-mysql"
client_args_log="${tmp_dir}/client-args.log"
cat > "${fake_client}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLIENT_ARGS_LOG}"
# Authenticate only when the defaults file carries the expected password.
for arg in "$@"; do
  case "${arg}" in
    --defaults-extra-file=*)
      grep -q 'password="correct-secret"' "${arg#--defaults-extra-file=}" && exit 0
      ;;
  esac
done
exit 1
EOF
chmod +x "${fake_client}"

CLIENT_ARGS_LOG="${client_args_log}" \
  verify_database_root_password "${fake_client}" /tmp/mysql.sock "correct-secret" ||
  fail "verification should succeed when the password authenticates"

if CLIENT_ARGS_LOG="${client_args_log}" \
   verify_database_root_password "${fake_client}" /tmp/mysql.sock "wrong-secret"; then
  fail "verification should fail when the password does not authenticate"
fi

# The password must never reach the process arguments, where any local account
# could read it from ps or /proc.
if grep -q 'correct-secret' "${client_args_log}"; then
  fail "the password must not be passed on the command line: $(cat "${client_args_log}")"
fi
grep -q -- '--defaults-extra-file=' "${client_args_log}" ||
  fail "verification should authenticate through a defaults file"

# The temporary credentials file must not survive the call.
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "${fake_client}" -type f -exec grep -l 'correct-secret' {} + 2>/dev/null || true)"
[[ -z "${leftover}" ]] || fail "the temporary credentials file should be removed: ${leftover}"

if verify_database_root_password "${tmp_dir}/does-not-exist" /tmp/mysql.sock "x"; then
  fail "verification should fail when the client binary is missing"
fi

# --- temporary-file cleanup must not leak into the caller ----------------------

# A `trap ... RETURN` set inside a function stays installed after that function
# returns and fires again when its caller returns, at which point the local it
# names is gone -- which under set -u aborts the caller with "unbound variable".
# Every function that creates a temporary credentials file is therefore called
# through a wrapper here, because calling it directly cannot expose the bug.
# This runs in its own process so set -e is genuinely in force: bash suppresses
# errexit inside a subshell that is part of an if or || construct. Its standard
# input is closed so the stub client below can never block waiting on a pipe
# that the test harness keeps open -- a regression must fail, not hang.
wrapper_status=0
bash -c '
  set -euo pipefail
  root="$1"; scratch="$2"
  source "${root}/include/common.sh"
  source "${root}/include/backup_lib.sh"
  source "${root}/include/restore_lib.sh"

  client="${scratch}/client"
  printf "#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nprintf \"ok\\\\n\"\n" > "${client}"
  chmod +x "${client}"

  backup_dir="${scratch}/backups"
  mysql_install_dir="${scratch}/mysql"
  mariadb_install_dir="${scratch}/mariadb"
  mysql_password=secret
  mysql_sock=/tmp/mysql.sock
  mkdir -p "${mysql_install_dir}/bin" "${backup_dir}"
  cp "${client}" "${mysql_install_dir}/bin/mysqldump"

  # Each wrapper returns after the inner function has returned; a leaked trap
  # fires exactly here.
  backup_mysql >/dev/null
  printf "past backup_mysql\n"

  verify_wrapper() { verify_database_root_password "${client}" /tmp/mysql.sock secret; }
  verify_wrapper
  printf "past verify_database_root_password\n"

  printf "CREATE DATABASE x;\n" > "${backup_dir}/mysql-all-20240101-000000.sql"
  restore_wrapper() {
    ok() { :; }
    restore_database_with MySQL "${client}" secret /tmp/mysql.sock \
      "${backup_dir}/mysql-all-20240101-000000.sql"
  }
  restore_wrapper >/dev/null
  printf "past restore_database_with\n"
' _ "${ROOT_DIR}" "${tmp_dir}" </dev/null > "${tmp_dir}/wrapper.out" 2>&1 || wrapper_status=$?

if ((wrapper_status != 0)); then
  fail "a temporary-file cleanup leaked into the caller: $(cat "${tmp_dir}/wrapper.out")"
fi
for stage in backup_mysql verify_database_root_password restore_database_with; do
  grep -q "past ${stage}" "${tmp_dir}/wrapper.out" ||
    fail "execution did not continue after ${stage}: $(cat "${tmp_dir}/wrapper.out")"
done

echo "PASS: credential handling"
