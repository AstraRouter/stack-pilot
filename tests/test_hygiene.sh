#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/security.sh"
source "${ROOT_DIR}/include/upgrade_lib.sh"

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

# --- state marker names are injective ----------------------------------------

assert_eq "nginx_1.28.1" "$(safe_state_name "nginx:1.28.1")" "a versioned step name should translate the colon"
assert_eq "php_84" "$(safe_state_name "php:84")" "a PHP step name should translate the colon"
assert_eq "nginx_" "$(safe_state_name "nginx:")" "a bare component prefix should translate the colon"

# Distinct step names must never share a marker file: one install step would
# silently be skipped because another already wrote its marker.
# (kept bash 3.2 compatible so the suite also runs on a developer macOS host)
seen_markers=""
for step in "nginx:1.28.1" "nginx:1.26.3" "php:84" "php:85" "mysql:8.0.42" "redis:7.2.10" "mariadb:11.4.9"; do
  marker="$(safe_state_name "${step}")"
  case " ${seen_markers} " in
    *" ${marker} "*) fail "step name '${step}' collides with an earlier step on marker '${marker}'" ;;
  esac
  seen_markers="${seen_markers} ${marker}"
done

# A character that would previously fold onto an existing marker is refused.
# The literal $(id) string is a rejection case, not a command to run.
# shellcheck disable=SC2016
for bad_step in "php_84" "php 84" "php/84" "php:84;rm" 'php:$(id)'; do
  if ( safe_state_name "${bad_step}" ) >/dev/null 2>&1; then
    fail "step name '${bad_step}' should be rejected rather than folded onto another marker"
  fi
done

# --- PHP security ini ---------------------------------------------------------

php_install_base="${tmp_dir}/services/php"
php_disable_functions="exec,system"
mkdir -p "$(php_install_dir_for_version 84)"

unset php_open_basedir
write_php_security_ini 84
security_ini="$(php_install_dir_for_version 84)/etc/php.d/99-security.ini"
grep -q '^expose_php = Off$' "${security_ini}" || fail "expose_php should be disabled"
grep -q '^disable_functions = exec,system$' "${security_ini}" || fail "disable_functions should be written"
# An empty "open_basedir =" is not a no-op: this file loads last and would clear
# a restriction configured anywhere else.
if grep -q '^open_basedir' "${security_ini}"; then
  fail "open_basedir must not be emitted when no value is configured: $(grep '^open_basedir' "${security_ini}")"
fi

php_open_basedir="/data/www/:/tmp/"
write_php_security_ini 84
grep -q '^open_basedir = /data/www/:/tmp/$' "${security_ini}" ||
  fail "a configured open_basedir should be written"
unset php_open_basedir

# --- version comparison and downgrade protection ------------------------------

assert_eq "0" "$(compare_versions "1.26.3" "1.26.3")" "identical versions should compare equal"
assert_eq "0" "$(compare_versions "1.26" "1.26.0")" "a missing component should count as zero"
assert_eq "1" "$(compare_versions "1.28.1" "1.26.3")" "a newer version should compare greater"
assert_eq "-1" "$(compare_versions "1.26.3" "1.28.1")" "an older version should compare less"
assert_eq "1" "$(compare_versions "1.28.10" "1.28.9")" "components should compare numerically, not as text"
assert_eq "1" "$(compare_versions "8.4.0" "8.0.42")" "a newer minor should outrank a larger patch"
assert_eq "0" "$(compare_versions "10.11.15" "10.11.15")" "double-digit components should compare equal"

assert_not_a_downgrade "Nginx" "1.26.3" "1.28.1" || fail "an upgrade should be allowed"
assert_not_a_downgrade "Nginx" "1.28.1" "1.28.1" || fail "a reinstall of the same version should be allowed"
assert_not_a_downgrade "Nginx" "" "1.28.1" || fail "a first install should be allowed"

if ( assert_not_a_downgrade "Nginx" "1.28.1" "1.26.3" ) >/dev/null 2>&1; then
  fail "a downgrade should be refused"
fi
(
  LNMP_ALLOW_DOWNGRADE=1
  warn() { :; }
  assert_not_a_downgrade "Nginx" "1.28.1" "1.26.3"
) >/dev/null 2>&1 || fail "an explicit override should permit a downgrade"

# --- password generation -------------------------------------------------------

generated="$(random_password 24)"
assert_eq "24" "${#generated}" "random_password should honour the requested length"
[[ "${generated}" =~ ^[A-Za-z0-9]+$ ]] || fail "random_password should stay alphanumeric"

# An unreadable entropy source must fail loudly instead of looping forever, so
# this runs under a hard time limit: a regression would otherwise hang the suite
# rather than fail it.
entropy_pid=""
bash -c '
  set -euo pipefail
  source "$1/include/common.sh"
  tr() { return 1; }
  head() { return 1; }
  random_password 16
' _ "${ROOT_DIR}" >/dev/null 2>&1 &
entropy_pid=$!
( sleep 15; kill -9 "${entropy_pid}" 2>/dev/null ) >/dev/null 2>&1 &
entropy_watchdog=$!
entropy_status=0
wait "${entropy_pid}" 2>/dev/null || entropy_status=$?
kill "${entropy_watchdog}" 2>/dev/null || true
wait "${entropy_watchdog}" 2>/dev/null || true
((entropy_status != 137)) || fail "random_password looped instead of giving up when no randomness was available"
((entropy_status != 0)) || fail "random_password should fail when no randomness is available"

# --- secrets are not written to stdout ----------------------------------------

# This runs at the end of a successful password reset, so it must never abort
# the caller, with or without a controlling terminal.
captured="$(print_secret "MySQL" "top-secret-value" 2>/dev/null)" ||
  fail "print_secret must not fail when no terminal is available"
# With a terminal the secret goes there and stdout stays clean; without one it
# falls back to stdout so the operator still sees the generated password.
[[ -z "${captured}" || "${captured}" == *"top-secret-value"* ]] ||
  fail "print_secret should either write to the terminal or fall back to stdout"

# --- ANSI escapes are stripped from logs --------------------------------------

assert_eq "Installed" "$(printf '\033[32mInstalled\033[0m' | strip_ansi_escapes)" \
  "colour sequences should be removed for log files"
assert_eq "plain text" "$(printf 'plain text' | strip_ansi_escapes)" \
  "text without escapes should pass through unchanged"

# --- PHP time zone ------------------------------------------------------------

# Exporting TZ only affects the installer process; PHP falls back to UTC unless
# date.timezone is written, so every site would report the wrong local time.
timezone="Asia/Shanghai"
write_php_timezone_ini 84
timezone_ini="$(php_install_dir_for_version 84)/etc/php.d/10-timezone.ini"
grep -q '^date.timezone = Asia/Shanghai$' "${timezone_ini}" ||
  fail "the configured time zone should reach PHP"
# php.d is read in lexical order, so this must sort before 99-security.ini.
[[ "$(basename "${timezone_ini}")" < "99-security.ini" ]] ||
  fail "the time-zone file must sort before the security overrides"

# The literal $(id) string is a rejection case, not a command to run.
# shellcheck disable=SC2016
for bad_zone in "Asia/Shanghai; rm -rf /" "../../etc/localtime" "Asia/Shang hai" '$(id)'; do
  if (timezone="${bad_zone}" write_php_timezone_ini 84) >/dev/null 2>&1; then
    fail "time zone '${bad_zone}' should be rejected"
  fi
done

# --- artifact permissions on the upgrade path ---------------------------------

file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then printf '%s' "${mode}"; return 0; fi
  mode="$(stat -f '%p' "$1" 2>/dev/null)" || return 1
  mode="${mode: -4}"
  [[ "${mode}" == 0* ]] && mode="${mode#0}"
  printf '%s' "${mode}"
}

# backup.sh sets umask 077; upgrade.sh runs the same archiving code and used to
# publish it at 0644 with options.conf and install.txt inside, in plaintext.
upgrade_root="${tmp_dir}/upgrade"
mkdir -p "${upgrade_root}"
printf 'mysql_password=SUPERSECRET\n' > "${upgrade_root}/options.conf"
printf 'nginx_ver=1.28.1\n' > "${upgrade_root}/versions.conf"
printf '  MySQL: SUPERSECRET\n' > "${upgrade_root}/install.txt"
(
  umask 022
  ROOT_DIR="${upgrade_root}"
  LNMP_OPTIONS_FILE="${upgrade_root}/options.conf"
  backup_dir="${upgrade_root}/backups"
  ok() { :; }
  # No extra component paths: the archive under test is the configuration one.
  # shellcheck disable=SC2119
  backup_before_upgrade
) || fail "the pre-upgrade configuration backup should succeed"

config_backup="$(find "${upgrade_root}/backups" -name 'upgrade-config-*.tar.gz' | head -1)"
[[ -n "${config_backup}" ]] || fail "the pre-upgrade backup should be written"
tar xzOf "${config_backup}" 2>/dev/null | grep -q SUPERSECRET ||
  fail "this test is vacuous unless the archive really contains the password"
assert_eq "600" "$(file_mode "${config_backup}")" \
  "an upgrade backup holding plaintext credentials must not be world-readable"
assert_eq "700" "$(file_mode "${upgrade_root}/backups")" \
  "the backup directory must not be world-readable"

# --- failed-upgrade directories are pruned ------------------------------------

prune_root="${tmp_dir}/services/example"
mkdir -p "${prune_root}"
for stamp in 20240101-000000 20240202-000000 20240303-000000; do
  mkdir -p "${prune_root}.failed-${stamp}-1-1"
done
(
  upgrade_keep_failed=1
  info() { :; }
  prune_failed_upgrade_dirs "${prune_root}"
)
remaining="$(find "${tmp_dir}/services" -maxdepth 1 -type d -name 'example.failed-*' | wc -l | tr -d ' ')"
assert_eq "1" "${remaining}" "only the newest failed-upgrade directory should be kept"
[[ -d "${prune_root}.failed-20240303-000000-1-1" ]] ||
  fail "the newest failed-upgrade directory is the one to keep"
[[ -d "${prune_root}" ]] || fail "pruning must not touch the live installation directory"

# A path the upgrade code would refuse to touch is left alone entirely.
mkdir -p "${tmp_dir}/usr-local"
(
  upgrade_keep_failed=0
  info() { :; }
  prune_failed_upgrade_dirs "/usr/local"
) || fail "pruning an unsafe path should be a no-op, not an error"

echo "PASS: hygiene and upgrade safety"
