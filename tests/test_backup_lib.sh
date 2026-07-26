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

# --- dump completeness -------------------------------------------------------

# --routines and --events default to off, so an "all databases" dump would
# silently omit every stored procedure, function, and scheduled event.
dump_args="$(cat "${args_file}")"
for option in --routines --events --triggers --single-transaction; do
  [[ "${dump_args}" == *"${option}"* ]] ||
    fail "the database dump must pass ${option}; got: ${dump_args}"
done

# --- per-site backup ----------------------------------------------------------

mkdir -p "${wwwroot_dir}/example.com" "${wwwroot_dir}/other.test"
printf 'site\n' > "${wwwroot_dir}/example.com/index.php"
sites="$(list_backup_sites | sort | xargs)"
[[ "${sites}" == "example.com other.test" ]] || fail "site listing should enumerate web-root sub-directories: got '${sites}'"

site_archive="$(backup_site example.com)"
[[ -s "${site_archive}" ]] || fail "a single-site backup should be published"
tar tzf "${site_archive}" | grep -q '^example.com/' || fail "the site archive should be rooted at the site directory"
if tar tzf "${site_archive}" | grep -q 'other.test'; then fail "a single-site backup must not include other sites"; fi

# The name becomes both a path component and part of the archive file name, so
# traversal has to be refused by validation rather than by the target happening
# not to exist. Each rejected name below resolves to a directory that really
# is there, so only the name check can stop it.
mkdir -p "${tmp_dir}/escaped" "${wwwroot_dir}/.hidden" "${wwwroot_dir}/with space"
for bad_site in "" "../escaped" ".hidden" "with space"; do
  if backup_site "${bad_site}" >/dev/null 2>&1; then fail "site name '${bad_site}' should be rejected"; fi
done
[[ -d "${tmp_dir}/escaped" ]] || fail "the traversal target should still exist"
if find "${backup_dir}" -name 'site-*escaped*' | grep -q .; then
  fail "a traversing site name must not produce an archive"
fi
if backup_site absent.test >/dev/null 2>&1; then fail "a missing site directory should be reported, not archived"; fi

# --- artifact permissions -----------------------------------------------------

file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then printf '%s' "${mode}"; return 0; fi
  mode="$(stat -f '%p' "$1" 2>/dev/null)" || return 1
  mode="${mode: -4}"
  [[ "${mode}" == 0* ]] && mode="${mode#0}"
  printf '%s' "${mode}"
}

# Dumps and site archives are readable business data; the caller's umask must
# not be the only thing keeping them private.
[[ "$(file_mode "${site_archive}")" == "600" ]] ||
  fail "published backups must be private: got mode $(file_mode "${site_archive}")"
[[ "$(file_mode "${backup_dir}")" == "700" ]] ||
  fail "the backup directory must be private: got mode $(file_mode "${backup_dir}")"

# --- Redis background save ----------------------------------------------------

redis_cli="${tmp_dir}/redis-cli"
redis_calls="${tmp_dir}/redis-calls"
cat > "${redis_cli}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${redis_calls}"
case "\$*" in
  *LASTSAVE*) grep -c BGSAVE "${redis_calls}" 2>/dev/null || printf '0' ;;
esac
EOF
chmod +x "${redis_cli}"
: > "${redis_calls}"

# Bound the completion wait: a regression that stops issuing BGSAVE must fail
# this suite in seconds rather than block it for the full production timeout.
export LNMP_REDIS_BGSAVE_ATTEMPTS=2

# SAVE blocks the Redis main thread for the whole write; BGSAVE forks.
redis_background_save "${redis_cli}" || fail "a completed background save should report success"
grep -q 'BGSAVE' "${redis_calls}" || fail "the Redis backup must use BGSAVE"
if grep -qw 'SAVE' "${redis_calls}"; then fail "the Redis backup must not issue a blocking SAVE"; fi

# --- retention ----------------------------------------------------------------

backup_keep_days=invalid
if (cleanup_backups >/dev/null 2>&1); then fail "invalid retention days should be rejected"; fi

: > "${backup_dir}/old.tar.gz"
touch -t 200001010000 "${backup_dir}/old.tar.gz"
: > "${backup_dir}/fresh.tar.gz"
# Exactly at the boundary: 7.5 days old under a 7-day retention. find's -mtime
# truncates to whole days, so "+7" only matches from 8 days and would keep this
# file for a further half day beyond what backup_keep_days says.
: > "${backup_dir}/boundary.tar.gz"
touch -t "$(date -v-7d -v-12H '+%Y%m%d%H%M' 2>/dev/null || date -d '7 days ago 12 hours ago' '+%Y%m%d%H%M')" \
  "${backup_dir}/boundary.tar.gz"

# 0 means "no retention limit". Reading it as a zero-day retention would delete
# every backup on the host, which no defaulted value should ever do.
backup_keep_days=0
cleanup_backups >/dev/null
[[ -f "${backup_dir}/old.tar.gz" ]] || fail "backup_keep_days=0 must disable retention, not delete everything"

backup_keep_days=7
cleanup_backups >/dev/null
if [[ -f "${backup_dir}/old.tar.gz" ]]; then fail "an expired backup should be removed"; fi
if [[ -f "${backup_dir}/boundary.tar.gz" ]]; then
  fail "a backup older than backup_keep_days must be removed at the exact boundary, not a day later"
fi
[[ -f "${backup_dir}/fresh.tar.gz" ]] || fail "a current backup must be kept"

echo "PASS: backup helpers"
