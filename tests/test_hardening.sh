#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/firewall.sh"

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

# Permission bits including setuid/setgid/sticky. BSD stat's %Lp drops the
# high bits, so the full mode is taken and trimmed to its last four digits.
file_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    printf '%s' "${mode}"
    return 0
  fi
  mode="$(stat -f '%p' "$1" 2>/dev/null)" || return 1
  mode="${mode: -4}"
  [[ "${mode}" == 0* ]] && mode="${mode#0}"
  printf '%s' "${mode}"
}

# --- SSH port discovery -------------------------------------------------------

# The port carrying the current session is the most reliable signal available.
assert_eq "2222" "$(
  SSH_CONNECTION='10.0.0.1 51234 10.0.0.2 2222'
  command_exists() { return 1; }
  sshd_listen_ports
)" "the active SSH session port should be detected from SSH_CONNECTION"

assert_eq "2222 2022" "$(
  SSH_CONNECTION='10.0.0.1 51234 10.0.0.2 2222'
  command_exists() { [[ "$1" == "sshd" ]]; }
  sshd() { printf 'port 2222\nport 2022\nlistenaddress 0.0.0.0\n'; }
  sshd_listen_ports
)" "sshd -T ports should be merged with the session port without duplicates"

assert_eq "22" "$(
  unset SSH_CONNECTION
  command_exists() { return 1; }
  LNMP_SSHD_CONFIG_GLOB_EMPTY=1
  sshd_listen_ports
)" "SSH port discovery should fall back to 22"

# A malformed SSH_CONNECTION must not produce an invalid rule.
assert_eq "22" "$(
  SSH_CONNECTION='garbage'
  command_exists() { return 1; }
  sshd_listen_ports
)" "an unparsable SSH_CONNECTION should fall back to 22"

assert_eq "22" "$(
  SSH_CONNECTION='10.0.0.1 51234 10.0.0.2 99999'
  command_exists() { return 1; }
  sshd_listen_ports
)" "an out-of-range SSH port should be rejected"

# --- firewall rule ordering ---------------------------------------------------

firewall_call_log="$(mktemp)"
trap 'rm -f "${firewall_call_log}"' EXIT

(
  manage_firewall=y
  nginx_http_port=80
  nginx_https_port=443
  command_exists() { [[ "$1" == "ufw" ]]; }
  sshd_listen_ports() { printf '2222'; }
  open_firewall_port() { printf 'allow:%s\n' "$1" >> "${firewall_call_log}"; }
  enable_firewall() { printf 'enable\n' >> "${firewall_call_log}"; }
  info() { :; }
  configure_firewall
) || fail "configure_firewall should succeed when optional port options are unset"

assert_eq "allow:2222 allow:80 allow:443 enable" "$(xargs < "${firewall_call_log}")" \
  "SSH must be allowed before service ports and the firewall enabled last"

# The previous implementation returned 1 whenever open_memcached_port was unset,
# which aborts the installer under set -e when called without "|| true".
(
  manage_firewall=y
  command_exists() { [[ "$1" == "ufw" ]]; }
  sshd_listen_ports() { printf '22'; }
  open_firewall_port() { :; }
  enable_firewall() { :; }
  info() { :; }
  configure_firewall
) || fail "configure_firewall must return success when no optional ports are opened"

: > "${firewall_call_log}"
# Settings are deliberately scoped to this subshell.
# shellcheck disable=SC2030,SC2031
(
  manage_firewall=y
  db_engine=mariadb
  open_database_port=y
  mariadb_port=3307
  open_redis_port=y
  redis_port=6380
  nginx_http_port=8080
  nginx_https_port=8443
  command_exists() { [[ "$1" == "ufw" ]]; }
  sshd_listen_ports() { printf '22'; }
  open_firewall_port() { printf 'allow:%s\n' "$1" >> "${firewall_call_log}"; }
  enable_firewall() { :; }
  info() { :; }
  configure_firewall
)
assert_eq "allow:22 allow:8080 allow:8443 allow:3307 allow:6380" "$(xargs < "${firewall_call_log}")" \
  "selected database and Redis ports should be opened"

# manage_firewall=n must not touch the firewall at all.
: > "${firewall_call_log}"
(
  manage_firewall=n
  command_exists() { [[ "$1" == "ufw" ]]; }
  open_firewall_port() { printf 'allow:%s\n' "$1" >> "${firewall_call_log}"; }
  enable_firewall() { printf 'enable\n' >> "${firewall_call_log}"; }
  configure_firewall
)
assert_eq "" "$(xargs < "${firewall_call_log}")" "manage_firewall=n should apply no firewall changes"

# With no backend present, nothing is attempted but the run still succeeds.
(
  manage_firewall=y
  command_exists() { return 1; }
  warn() { :; }
  configure_firewall
) || fail "configure_firewall should succeed when no firewall backend is installed"

# --- firewall activation ------------------------------------------------------

: > "${firewall_call_log}"
(
  command_exists() { [[ "$1" == "ufw" ]]; }
  firewall_is_active() { return 1; }
  ufw() { printf 'ufw:%s\n' "$*" >> "${firewall_call_log}"; }
  warn() { :; }
  enable_firewall
)
assert_eq "ufw:--force enable" "$(xargs < "${firewall_call_log}")" \
  "an inactive ufw should be enabled non-interactively"

: > "${firewall_call_log}"
(
  command_exists() { [[ "$1" == "ufw" ]]; }
  firewall_is_active() { return 0; }
  ufw() { printf 'ufw:%s\n' "$*" >> "${firewall_call_log}"; }
  info() { :; }
  enable_firewall
)
assert_eq "" "$(xargs < "${firewall_call_log}")" "an already active firewall should not be re-enabled"

# --- runtime directory permissions -------------------------------------------

layout_root="$(mktemp -d)"
# Settings are deliberately scoped to this subshell.
# shellcheck disable=SC2030,SC2031
(
  services_base_dir="${layout_root}/services"
  data_base_dir="${layout_root}/data"
  runtime_base_dir="${layout_root}/runtime"
  pid_dir="${runtime_base_dir}/pid"
  sock_dir="${runtime_base_dir}/sock"
  logs_dir="${runtime_base_dir}/logs"
  nginx_log_dir="${logs_dir}/nginx"
  php_log_dir="${logs_dir}/php"
  mysql_log_dir="${logs_dir}/mysql"
  mariadb_log_dir="${logs_dir}/mariadb"
  redis_log_dir="${logs_dir}/redis"
  memcached_log_dir="${logs_dir}/memcached"
  init_layout_dirs
)
assert_eq "755" "$(file_mode "${layout_root}/runtime/pid")" \
  "the pid directory must not be world-writable"
assert_eq "755" "$(file_mode "${layout_root}/runtime/sock")" \
  "the socket directory must not be world-writable (it would allow local socket interception)"

# A service user is granted access to its own runtime directory instead.
(
  getent() { return 0; }
  chown() { :; }
  grant_runtime_dir_access "${layout_root}/runtime/sock" mysql
)
assert_eq "2775" "$(file_mode "${layout_root}/runtime/sock")" \
  "grant_runtime_dir_access should make the directory setgid group-writable"

# Missing group: leave the directory alone and warn rather than widening it.
grant_warning="$(
  getent() { return 1; }
  grant_runtime_dir_access "${layout_root}/runtime/pid" nosuchgroup 2>&1 >/dev/null
)"
assert_eq "755" "$(file_mode "${layout_root}/runtime/pid")" \
  "a missing service group must not change directory permissions"
[[ "${grant_warning}" == *"nosuchgroup"* ]] || fail "a missing service group should be reported"

grant_runtime_dir_access "" mysql || fail "an empty directory argument should be a no-op"
grant_runtime_dir_access "${layout_root}/absent" mysql || fail "an absent directory should be a no-op"
rm -rf "${layout_root}"

# --- port validation ----------------------------------------------------------

validate_port 22 || fail "port 22 should be valid"
if validate_port 99999999999999999999; then fail "an over-long numeric port should be rejected"; fi
if validate_port 018446744073709551617; then fail "a port that overflows 64-bit arithmetic should be rejected"; fi

# --- bind address and memory validation --------------------------------------

for address in 127.0.0.1 0.0.0.0 ::1 localhost db.internal 10.0.0.5; do
  validate_bind_address "${address}" || fail "${address} should be a valid bind address"
done
# Values that could add an argument to a systemd ExecStart line.
# The literal $(id) string is a rejection case, not a command to run.
# shellcheck disable=SC2016
for address in "" "0.0.0.0 -U 0" "-U" "127.0.0.1;reboot" '$(id)' "127.0.0.1
0.0.0.0"; do
  if validate_bind_address "${address}"; then fail "bind address '${address}' should be rejected"; fi
done

for memory in 1 64 1024 1048576 0064; do
  validate_memory_mb "${memory}" || fail "${memory} should be a valid memory size"
done
for memory in "" 0 1048577 abc "128 -U 0" 99999999999999999999; do
  if validate_memory_mb "${memory}"; then fail "memory size '${memory}' should be rejected"; fi
done

# A hostile options.conf must not reach the systemd unit even without a prompt.
# memcached.sh is sourced first so the stub below is not overwritten by it, and
# every variable the unit interpolates is set so the subshell can only fail on
# the validation itself rather than on set -u.
source "${ROOT_DIR}/include/memcached.sh"

# Settings are deliberately scoped to the subshell.
# shellcheck disable=SC2030,SC2031
write_unit_with() {
  (
    memcached_install_dir="/opt/memcached"
    memcached_bind="$1"
    memcached_memory="$2"
    memcached_port="$3"
    memcached_service_file_path() { printf '/dev/null'; }
    warn() { :; }
    write_memcached_service
  ) >/dev/null 2>&1
}

write_unit_with "127.0.0.1" 64 11211 || fail "a valid memcached configuration should write the unit"
if write_unit_with "0.0.0.0 -U 0" 64 11211; then
  fail "an injected memcached bind address should abort the unit write"
fi
if write_unit_with "127.0.0.1" "64 -U 0" 11211; then
  fail "an injected memcached memory value should abort the unit write"
fi
if write_unit_with "127.0.0.1" 64 "11211 -U 0"; then
  fail "an injected memcached port should abort the unit write"
fi

# --- bounded retry loops ------------------------------------------------------

source "${ROOT_DIR}/include/install/wizard.sh"

# Run one prompt call under a hard time limit, in a clean shell. A regression
# that reintroduces an unbounded prompt loop must fail this suite, not hang it.
# Returns the prompt's exit status; aborts the suite if the watchdog fires.
run_prompt_bounded() {
  local limit="$1" call="$2" pid watchdog status=0
  bash -c '
    set -euo pipefail
    source "$1/include/common.sh"
    source "$1/include/install/wizard.sh"
    LNMP_PROMPT_MAX_ATTEMPTS=3
    warn() { :; }
    eval "$2" </dev/null
  ' _ "${ROOT_DIR}" "${call}" >/dev/null 2>&1 &
  pid=$!
  ( sleep "${limit}"; kill -9 "${pid}" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "${pid}" 2>/dev/null || status=$?
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true
  ((status == 137)) && fail "prompt call did not terminate within ${limit}s: ${call}"
  return "${status}"
}

# At EOF every read returns immediately, so a loop that only exits on a valid
# value can never make progress. It must give up instead of spinning. The same
# applies when the default itself, loaded from options.conf, is invalid.
for unsatisfiable in \
  'prompt_port_value "Port" "not-a-port"' \
  'prompt_bind_address_value "Bind" "0.0.0.0 -U 0"' \
  'prompt_memory_mb_value "Memory" "abc"'; do
  if run_prompt_bounded 15 "${unsatisfiable}"; then
    fail "should abort when the value can never validate: ${unsatisfiable}"
  fi
done

retry_error="$(
  (
    LNMP_PROMPT_MAX_ATTEMPTS=3
    warn() { :; }
    prompt_port_value "Port" "not-a-port" </dev/null
  ) 2>&1 >/dev/null || true
)"
[[ "${retry_error}" == *"3 attempts"* ]] || fail "the retry limit should be reported: got '${retry_error}'"

# A valid default still returns immediately at EOF.
assert_eq "8080" "$(
  warn() { :; }
  prompt_port_value "Port" "8080" </dev/null 2>/dev/null
)" "a valid default should be accepted without further input"

# --- uninstall guards ---------------------------------------------------------

source "${ROOT_DIR}/include/uninstall_lib.sh"

symlink_dir="$(mktemp -d)"
printf 'x\n' > "${symlink_dir}/unrelated-target"
ln -s "${symlink_dir}/unrelated-target" "${symlink_dir}/unrelated-link"
# An empty prefix previously degraded the match pattern to /* and removed any
# absolute symlink.
remove_managed_symlink "${symlink_dir}/unrelated-link" ""
[[ -L "${symlink_dir}/unrelated-link" ]] || fail "an empty prefix must not remove unrelated symlinks"
remove_managed_symlink "${symlink_dir}/unrelated-link" "${symlink_dir}"
if [[ -L "${symlink_dir}/unrelated-link" ]]; then fail "a matching prefix should remove the managed symlink"; fi
rm -rf "${symlink_dir}"

# --- service account validation ------------------------------------------------

for account in www nginx _mysql php-fpm redis8 a; do
  validate_unix_username "${account}" || fail "'${account}' should be a valid account name"
done
# These reach "user X Y;" in nginx.conf, ./configure --with-fpm-user=, php-fpm.d,
# and useradd, all unquoted.
# The literal $(id) string is a rejection case, not a command to run.
# shellcheck disable=SC2016
for account in "" "www www" "www;reboot" "www
root" "1www" "-www" "Www" '$(id)' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
  if validate_unix_username "${account}"; then fail "account name '${account}' should be rejected"; fi
done

# --- PHP-FPM pool tuning ---------------------------------------------------------

source "${ROOT_DIR}/include/php.sh"

set_valid_fpm_tunables() {
  php_pm=dynamic
  php_pm_max_children=20
  php_pm_start_servers=4
  php_pm_min_spare_servers=2
  php_pm_max_spare_servers=8
  php_memory_limit=256M
  php_upload_max_filesize=50M
  php_post_max_size=50M
  php_max_execution_time=300
}

( set_valid_fpm_tunables; assert_php_fpm_tunables ) ||
  fail "the shipped defaults should pass validation"

# php-fpm refuses to start on any of these, and a value carrying a newline would
# append further php_admin_value directives to the pool.
for mutation in \
  'php_pm=aggressive' \
  'php_pm=' \
  'php_pm_max_children=0' \
  'php_pm_max_children=abc' \
  'php_memory_limit=256MB' \
  'php_memory_limit=' \
  'php_post_max_size="50M
php_admin_value[open_basedir]="' \
  'php_max_execution_time=-1' \
  'php_pm_start_servers=1' \
  'php_pm_start_servers=99' \
  ; do
  if ( set_valid_fpm_tunables; eval "${mutation}"; assert_php_fpm_tunables ) >/dev/null 2>&1; then
    fail "php-fpm tuning '${mutation}' should be rejected"
  fi
done

# static and ondemand do not use the spare-server bounds, so they must not be
# checked against them.
( set_valid_fpm_tunables; php_pm=static; php_pm_start_servers=1; assert_php_fpm_tunables ) ||
  fail "pm=static should not be held to the dynamic spare-server ordering"

# --- size and integer helpers ----------------------------------------------------

assert_eq "50m" "$(normalize_size_value 50M)" "megabytes should normalize to Nginx form"
assert_eq "1024k" "$(normalize_size_value 1024K)" "kilobytes should normalize"
assert_eq "2g" "$(normalize_size_value 2G)" "gigabytes should normalize"
assert_eq "1048576" "$(normalize_size_value 1048576)" "a plain byte count should pass through"
for bad_size in "" 0 "50 M" "50MB" "-50M" "50T" "50M;id"; do
  if normalize_size_value "${bad_size}" >/dev/null 2>&1; then
    fail "size '${bad_size}' should be rejected"
  fi
done

validate_positive_integer 1 10 || fail "1 should be within 1..10"
validate_positive_integer 10 10 || fail "the upper bound should be inclusive"
for bad_int in "" 0 11 -1 abc "5 6" 9999999999; do
  if validate_positive_integer "${bad_int}" 10; then fail "integer '${bad_int}' should be rejected"; fi
done

for zone in UTC Asia/Shanghai America/Argentina/Buenos_Aires Etc/GMT+8; do
  validate_timezone "${zone}" || fail "'${zone}' should be a valid time zone"
done
# The literal $(date) string is a rejection case, not a command to run.
# shellcheck disable=SC2016
for zone in "" "Asia/Shang hai" "../etc/localtime" "Asia/Shanghai;id" '$(date)' "/UTC"; do
  if validate_timezone "${zone}"; then fail "time zone '${zone}' should be rejected"; fi
done

# --- supported PHP versions come from one place ----------------------------------

# The installer, the vhost menu, and the service menu all read this list. A
# version present in only some of them can be built but never selected, or
# offered and then fail to build.
# Captured once: piping into `grep -q` closes the pipe early, which under
# pipefail reports the producer as failing.
menu_entries="$(php_version_entries)"
for version in $(php_supported_versions); do
  php_version_supported "${version}" || fail "${version} should be reported as supported"
  php_fpm_port "${version}" >/dev/null || fail "${version} should have an FPM port"
  normalize_php_versions "${version}" >/dev/null || fail "${version} should normalize"
  [[ "${menu_entries}" == *"${version}|PHP "* ]] || fail "${version} should appear in the menu entries"
done
for version in 53 86 99 abc ""; do
  if php_version_supported "${version}"; then fail "PHP '${version}' should not be supported"; fi
  if php_fpm_port "${version}" >/dev/null 2>&1; then fail "PHP '${version}' should have no FPM port"; fi
done
assert_eq "$(php_supported_versions | wc -w | tr -d ' ')" "$(printf '%s\n' "${menu_entries}" | wc -l | tr -d ' ')" \
  "every supported version should produce exactly one menu entry"

echo "PASS: firewall and runtime hardening"
