#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/backup_lib.sh"
source "${ROOT_DIR}/include/restore_lib.sh"

# The stub database client below reads standard input so it can record the dump
# it is fed. Production code also invokes it without a redirect (FLUSH
# PRIVILEGES), so an inherited open pipe would leave it blocked forever. Closing
# standard input here means a regression fails this suite instead of hanging it.
exec </dev/null

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

backup_dir="${tmp_dir}/backups"
wwwroot_dir="${tmp_dir}/www"
redis_data_dir="${tmp_dir}/redisdata"
user=stackpilot
group=stackpilot
LNMP_RESTORE_SKIP_SERVICE_CONTROL=1

mkdir -p "${wwwroot_dir}/example.com" "${backup_dir}"
printf 'original\n' > "${wwwroot_dir}/example.com/index.php"

# --- round trip ---------------------------------------------------------------

# A backup that cannot be restored is not a backup. This is the whole point of
# the pairing, so it is asserted end to end rather than per function.
site_archive="$(backup_site example.com)"
printf 'edited by mistake\n' > "${wwwroot_dir}/example.com/index.php"
(
  id() { return 1; }
  ok() { :; }
  restore_web_archive "${site_archive}"
) >/dev/null || fail "a site archive should restore"
assert_eq "original" "$(cat "${wwwroot_dir}/example.com/index.php")" \
  "restoring should bring back the archived content"

# The state that was overwritten is archived first, so the restore itself can be
# undone.
pre_restore="$(find "${backup_dir}" -name 'pre-restore-wwwroot-*.tar.gz' | head -1)"
[[ -n "${pre_restore}" ]] || fail "a restore should archive the current state before overwriting it"

web_archive="$(backup_web)"
rm -rf "${wwwroot_dir}"
(
  id() { return 1; }
  ok() { :; }
  restore_web_archive "${web_archive}"
) >/dev/null || fail "a full web-root archive should restore"
[[ -f "${wwwroot_dir}/example.com/index.php" ]] || fail "the whole web root should come back"

# --- source validation --------------------------------------------------------

outside="${tmp_dir}/outside.tar.gz"
LC_ALL=C tar czf "${outside}" -C "${wwwroot_dir}" example.com
if restore_web_archive "${outside}" >/dev/null 2>&1; then
  fail "restoring from outside the backup directory should be refused"
fi
if restore_web_archive "${backup_dir}/absent.tar.gz" >/dev/null 2>&1; then
  fail "a missing archive should be refused"
fi
: > "${backup_dir}/empty.tar.gz"
if restore_web_archive "${backup_dir}/empty.tar.gz" >/dev/null 2>&1; then
  fail "an empty archive should be refused"
fi
cp "${site_archive}" "${backup_dir}/mystery-file.tar.gz"
if restore_web_archive "${backup_dir}/mystery-file.tar.gz" >/dev/null 2>&1; then
  fail "an archive whose name does not say what it holds should be refused"
fi

# A corrupt or truncated archive lists no members. Looping over an empty stream
# would report it as safe and go on to extract it, so tar's own status decides.
printf 'not a gzip stream at all\n' > "${backup_dir}/site-corrupt.tar.gz"
if assert_archive_is_relative "${backup_dir}/site-corrupt.tar.gz" >/dev/null 2>&1; then
  fail "an unreadable archive should be refused, not treated as containing nothing dangerous"
fi
if restore_web_archive "${backup_dir}/site-corrupt.tar.gz" >/dev/null 2>&1; then
  fail "a corrupt archive should never reach extraction"
fi

# --- ownership is scoped to what was restored -------------------------------

# Restoring one site must not rewrite the ownership of every other site sharing
# the web root.
chown_log="${tmp_dir}/chown.log"
: > "${chown_log}"
mkdir -p "${wwwroot_dir}/untouched.test"
printf 'other site\n' > "${wwwroot_dir}/untouched.test/index.php"
(
  id() { return 0; }
  chown() { printf '%s\n' "$*" >> "${chown_log}"; }
  ok() { :; }
  restore_web_archive "${site_archive}"
) >/dev/null || fail "the single-site restore should succeed"
assert_eq "-R stackpilot:stackpilot ${wwwroot_dir}/example.com" "$(cat "${chown_log}")" \
  "only the restored site should be re-owned"
[[ "$(cat "${wwwroot_dir}/untouched.test/index.php")" == "other site" ]] ||
  fail "an unrelated site must not be modified by a single-site restore"

# A full web-root restore legitimately covers the whole tree.
: > "${chown_log}"
(
  id() { return 0; }
  chown() { printf '%s\n' "$*" >> "${chown_log}"; }
  ok() { :; }
  restore_web_archive "${web_archive}"
) >/dev/null || fail "the full web-root restore should succeed"
grep -q -- "-R stackpilot:stackpilot ${wwwroot_dir}\$" "${chown_log}" ||
  fail "a full restore should re-own the web root itself: $(cat "${chown_log}")"

# --- traversal ----------------------------------------------------------------

# An archive naming ".." or an absolute path would write outside the directory
# being restored into.
escape_src="${tmp_dir}/escape"
mkdir -p "${escape_src}/sub"
printf 'payload\n' > "${escape_src}/sub/payload"
LC_ALL=C tar czf "${backup_dir}/site-traversal.tar.gz" -C "${escape_src}" ../escape/sub 2>/dev/null ||
  LC_ALL=C tar czf "${backup_dir}/site-traversal.tar.gz" -C "${tmp_dir}" ./escape/../escape/sub
if assert_archive_is_relative "${backup_dir}/site-traversal.tar.gz" >/dev/null 2>&1; then
  fail "an archive containing .. should be rejected"
fi

absolute_archive="${backup_dir}/site-absolute.tar.gz"
LC_ALL=C tar czf "${absolute_archive}" -P "${escape_src}/sub/payload" 2>/dev/null
if tar tzf "${absolute_archive}" 2>/dev/null | grep -q '^/'; then
  if assert_archive_is_relative "${absolute_archive}" >/dev/null 2>&1; then
    fail "an archive containing an absolute path should be rejected"
  fi
fi

assert_archive_is_relative "${site_archive}" || fail "an ordinary site archive should be accepted"

# --- database restore ---------------------------------------------------------

fake_client="${tmp_dir}/mysql"
client_args="${tmp_dir}/client-args"
client_stdin="${tmp_dir}/client-stdin"
cat > "${fake_client}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${client_args}"
cat >> "${client_stdin}"
EOF
chmod +x "${fake_client}"
: > "${client_args}"
: > "${client_stdin}"

printf 'CREATE DATABASE restored;\n' > "${backup_dir}/mysql-all-20240101-000000.sql"
(
  ok() { :; }
  restore_database_with MySQL "${fake_client}" 'secret value' /tmp/mysql.sock \
    "${backup_dir}/mysql-all-20240101-000000.sql"
) >/dev/null || fail "a database dump should restore"

grep -q -- '--defaults-extra-file=' "${client_args}" ||
  fail "the restore must authenticate through a protected option file"
if grep -q 'secret value' "${client_args}"; then
  fail "the database password leaked into process arguments"
fi
grep -q 'CREATE DATABASE restored;' "${client_stdin}" || fail "the dump should be fed to the client"
# An --all-databases dump replaces the mysql schema, so the in-memory grant
# tables are stale until they are reloaded.
grep -q 'FLUSH PRIVILEGES' "${client_args}" || fail "grants should be reloaded after the restore"

echo "PASS: restore safety"
