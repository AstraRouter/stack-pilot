#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/nginx.sh"
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/logrotate.sh"
source "${ROOT_DIR}/include/fail2ban.sh"
source "${ROOT_DIR}/include/install/wizard.sh"
source "${ROOT_DIR}/include/install/unattended.sh"

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

# The shipped example file is the contract for unattended mode: it must be a
# complete, valid answer set on its own.
LNMP_ROOT_DIR="${ROOT_DIR}"
LNMP_OPTIONS_FILE="${tmp_dir}/options.conf"
cp "${ROOT_DIR}/options.example.conf" "${LNMP_OPTIONS_FILE}"
# shellcheck disable=SC1090
source "${LNMP_OPTIONS_FILE}"
refresh_component_version_urls() { return 0; }

# --- component resolution ------------------------------------------------------

# db_engine is derived from the component list, exactly as the wizard derives
# it, so a stale value in the file cannot install an engine that was not chosen.
(
  install_components="nginx php redis"
  db_engine=mysql
  resolve_unattended_components
  assert_eq "none" "${db_engine}" "an unlisted database engine should resolve to none"
  assert_eq "y" "${install_redis}" "redis in the component list should set install_redis"
  assert_eq "n" "${install_composer}" "composer absent from the list should clear install_composer"
) || exit 1

(
  install_components="nginx mariadb"
  db_engine=mysql
  resolve_unattended_components
  assert_eq "mariadb" "${db_engine}" "the listed engine should win over a stale db_engine"
) || exit 1

# Installing two engines on the same port would silently leave one broken.
if (install_components="mysql mariadb"; resolve_unattended_components) >/dev/null 2>&1; then
  fail "listing both database engines should be refused"
fi
if (install_components="nginx nosuchthing"; resolve_unattended_components) >/dev/null 2>&1; then
  fail "an unknown component should be refused"
fi
if (install_components=""; resolve_unattended_components) >/dev/null 2>&1; then
  fail "an empty component list should be refused"
fi
# fail2ban is a real component, not a typo.
(install_components="nginx fail2ban"; resolve_unattended_components) >/dev/null ||
  fail "fail2ban should be installable"

# --- password handling ---------------------------------------------------------

# An empty password means "generate one", as it does in the wizard.
generated="$(
  db_engine=mysql
  mysql_password=""
  install_components="mysql"
  resolve_unattended_passwords
  printf '%s' "${mysql_password}"
)"
((${#generated} == 20)) || fail "an empty database password should be generated, got '${generated}'"

# No prompt loop rejected these first, so unattended mode has to.
if (db_engine=mysql; mysql_password="ab"; resolve_unattended_passwords) >/dev/null 2>&1; then
  fail "a too-short database password should be refused"
fi
if (db_engine=mysql; mysql_password="a'b'c'd'e"; resolve_unattended_passwords) >/dev/null 2>&1; then
  fail "a database password containing a single quote should be refused"
fi
if (install_components="redis"; db_engine=none; redis_password="has space"; resolve_unattended_passwords) >/dev/null 2>&1; then
  fail "a Redis password with a space should be refused"
fi
# An empty Redis password is a deliberate choice: no authentication.
(install_components="redis"; db_engine=none; redis_password=""; resolve_unattended_passwords) ||
  fail "an empty Redis password should be accepted as 'no authentication'"

# --- option validation ---------------------------------------------------------

nginx_install_dir="${tmp_dir}/nginx"
mkdir -p "${nginx_install_dir}/conf"

validate_unattended_run() {
  (
    resolve_unattended_components
    eval "$1"
    validate_unattended_options
  ) >/dev/null 2>&1
}

validate_unattended_run ':' || fail "the shipped options.example.conf should validate unchanged"

for mutation in \
  'timezone="Asia/Shang hai"' \
  'timezone=""' \
  'user="www www"' \
  'group="1www"' \
  'wwwroot_dir="relative/path"' \
  'backup_dir="/data/backup; rm -rf /"' \
  'php_versions="86"' \
  'php_profile="custom-thing"' \
  'php_pm="turbo"' \
  'php_post_max_size="50MB"' \
  'nginx_http_port="80 -U 0"' \
  'nginx_http_port=443' \
  'nginx_client_max_body_size="1 gigabyte"' \
  'nginx_http3=y; nginx_ver=1.24.0' \
  'nginx_rate_limit=y; nginx_rate_limit_rps=0' \
  'manage_firewall=maybe' \
  ; do
  if validate_unattended_run "${mutation}"; then
    fail "unattended mode should refuse '${mutation}' instead of installing with it"
  fi
done

# --- log rotation ---------------------------------------------------------------

logs_dir="${tmp_dir}/logs"
nginx_log_dir="${logs_dir}/nginx"
php_log_dir="${logs_dir}/php"
redis_log_dir="${logs_dir}/redis"
mysql_log_dir="${logs_dir}/mysql"
mariadb_log_dir="${logs_dir}/mariadb"
memcached_log_dir="${logs_dir}/memcached"
pid_dir="${tmp_dir}/pid"
nginx_pid="${pid_dir}/nginx.pid"
install_components="nginx php redis"
db_engine=none

rotation="$(render_logrotate_config)"
[[ "${rotation}" == *"${nginx_log_dir}/*.log {"* ]] || fail "nginx logs should be rotated"
[[ "${rotation}" == *"${php_log_dir}/*.log {"* ]] || fail "PHP-FPM logs should be rotated"
[[ "${rotation}" == *"${redis_log_dir}/*.log {"* ]] || fail "Redis logs should be rotated"
[[ "${rotation}" != *"${mysql_log_dir}"* ]] || fail "an uninstalled database should not be rotated"
[[ "${rotation}" == *"rotate 14"* ]] || fail "the retention count should be applied"

# Per stanza, not "somewhere in the file": the point is that each service gets
# the mechanism it actually supports.
logrotate_stanza() {
  printf '%s\n' "${rotation}" | awk -v head="$1 {" '
    index($0, head) == 1 { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }'
}

# Nginx and PHP-FPM reopen their log file on SIGUSR1, so the file is renamed and
# the process told to start a new one, losing nothing.
for signalled in "${nginx_log_dir}" "${php_log_dir}"; do
  stanza="$(logrotate_stanza "${signalled}/*.log")"
  [[ -n "${stanza}" ]] || fail "no rotation stanza was produced for ${signalled}"
  [[ "${stanza}" == *"kill -USR1"* ]] || fail "${signalled} should be rotated by signalling the process"
  [[ "${stanza}" != *"copytruncate"* ]] ||
    fail "${signalled} can reopen its log, so it must not be truncated underneath a running process"
done

# Redis holds its log open and only reopens on restart, so there is nothing to
# signal and the file has to be truncated in place.
redis_stanza="$(logrotate_stanza "${redis_log_dir}/*.log")"
[[ "${redis_stanza}" == *"copytruncate"* ]] || fail "Redis logs need copytruncate"
[[ "${redis_stanza}" != *"kill -"* ]] || fail "Redis does not reopen its log on a signal"

(logrotate_keep=0 render_logrotate_config) >/dev/null 2>&1 &&
  fail "a zero retention count should be refused"
(logrotate_interval=hourly render_logrotate_config) >/dev/null 2>&1 &&
  fail "an unsupported rotation interval should be refused"

# --- fail2ban jails --------------------------------------------------------------

jails="$(render_fail2ban_jails)"
[[ "${jails}" == *"[sshd]"* ]] || fail "the sshd jail should always be enabled"
[[ "${jails}" == *"[nginx-http-auth]"* ]] || fail "the nginx auth jail should be enabled when nginx is installed"
[[ "${jails}" == *"logpath = ${nginx_log_dir}/*error.log"* ]] || fail "jails should point at this install's log paths"
# nginx-limit-req only matches the lines limit_req writes, so it is pointless
# unless rate limiting is on.
[[ "${jails}" != *"[nginx-limit-req]"* ]] || fail "the limit_req jail should follow the rate-limit option"
[[ "$(nginx_rate_limit=y render_fail2ban_jails)" == *"[nginx-limit-req]"* ]] ||
  fail "enabling rate limiting should enable the matching jail"
[[ "$(install_components="fail2ban" render_fail2ban_jails)" != *"[nginx-http-auth]"* ]] ||
  fail "nginx jails should not be written when nginx is not installed"

for bad in 'fail2ban_bantime=0' 'fail2ban_findtime=abc' 'fail2ban_maxretry=-1'; do
  if (eval "${bad}"; render_fail2ban_jails) >/dev/null 2>&1; then
    fail "fail2ban setting '${bad}' should be refused"
  fi
done

echo "PASS: unattended install and maintenance configuration"
