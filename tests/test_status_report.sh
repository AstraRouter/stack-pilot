#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/logrotate.sh"
source "${ROOT_DIR}/include/fail2ban.sh"
source "${ROOT_DIR}/include/vhost_lib.sh"
source "${ROOT_DIR}/include/status_report.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

nginx_install_dir="${tmp_dir}/services/nginx"
php_install_base="${tmp_dir}/services/php"
mysql_install_dir="${tmp_dir}/services/mysql"
mariadb_install_dir="${tmp_dir}/services/mariadb"
redis_install_dir="${tmp_dir}/services/redis"
memcached_install_dir="${tmp_dir}/services/memcached"
composer_install_dir="${tmp_dir}/services/composer"
wwwroot_dir="${tmp_dir}/www"
logs_dir="${tmp_dir}/logs"
backup_dir="${tmp_dir}/backups"
runtime_base_dir="${tmp_dir}"
LNMP_SRC_DIR="${tmp_dir}/src"
timezone="Asia/Shanghai"
nginx_http_port=80
redis_port=6379

mkdir -p "${nginx_install_dir}/sbin" "$(vhost_conf_dir)" "${wwwroot_dir}" "${logs_dir}" "${backup_dir}" "${LNMP_SRC_DIR}"
write_component_version_marker "${nginx_install_dir}" 1.28.1
mkdir -p "${redis_install_dir}"
write_component_version_marker "${redis_install_dir}" 8.4.0

# --- component table ------------------------------------------------------------

# The report must work on a host without systemd, where the state of a service
# genuinely cannot be determined; saying so is better than claiming "stopped".
components="$(
  command_exists() { return 1; }
  print_status_components
)"
[[ "${components}" == *"Nginx"* ]] || fail "an installed component should be listed"
[[ "${components}" == *"1.28.1"* ]] || fail "the recorded version should be reported"
[[ "${components}" == *"Redis"* ]] || fail "Redis should be listed once it is installed"
[[ "${components}" != *"MySQL"* ]] || fail "a component that is not installed should not be listed"
[[ "${components}" == *"unknown (no systemctl)"* ]] ||
  fail "an undeterminable service state should say so rather than guess"

# --- certificate expiry ---------------------------------------------------------

printf 'server {\n    root %s;\n}\n' "${wwwroot_dir}/plain.test" > "$(vhost_conf_file "plain.test")"
sites="$(print_status_sites)"
[[ "${sites}" == *"plain.test"* ]] || fail "a configured site should be listed"
[[ "${sites}" == *"no certificate"* ]] || fail "a site without a certificate should be reported as HTTP"

if command -v openssl >/dev/null 2>&1; then
  cert_dir="$(ssl_cert_dir "tls.test")"
  mkdir -p "${cert_dir}"
  printf 'server {\n    root %s;\n}\n' "${wwwroot_dir}/tls.test" > "$(vhost_conf_file "tls.test")"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj '/CN=tls.test' -keyout "${cert_dir}/privkey.pem" -out "${cert_dir}/fullchain.pem" >/dev/null 2>&1
  expiry="$(status_certificate_expiry "${cert_dir}/fullchain.pem")"
  # Read straight from the certificate, so a hand-installed one is reported too.
  [[ "${expiry}" == *"days left"* || "${expiry}" == *"expires "* ]] ||
    fail "a valid certificate should report its remaining lifetime: got '${expiry}'"

  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=old.test' -keyout "${cert_dir}/old-key.pem" -out "${cert_dir}/old.pem" >/dev/null 2>&1
  [[ "$(status_certificate_expiry "${cert_dir}/old.pem")" != *"EXPIRED"* ]] ||
    fail "a certificate valid for another day must not be reported as expired"
fi

# An unreadable file is reported, not treated as a fatal error mid-report.
printf 'not a certificate\n' > "${tmp_dir}/broken.pem"
status_certificate_expiry "${tmp_dir}/broken.pem" >/dev/null ||
  fail "an unreadable certificate must not abort the report"

# --- maintenance ------------------------------------------------------------------

# Silence about missing log rotation is how a disk fills up unnoticed.
maintenance="$(
  LNMP_LOGROTATE_FILE="${tmp_dir}/absent-logrotate"
  command_exists() { return 1; }
  print_status_maintenance
)"
[[ "${maintenance}" == *"NOT configured"* ]] || fail "missing log rotation should be called out"
[[ "${maintenance}" == *"not scheduled"* ]] || fail "missing certificate renewal should be called out"

: > "${tmp_dir}/present-logrotate"
maintenance="$(
  LNMP_LOGROTATE_FILE="${tmp_dir}/present-logrotate"
  command_exists() { return 1; }
  print_status_maintenance
)"
[[ "${maintenance}" == *"Log rotation: configured"* ]] || fail "configured log rotation should be reported"

# --- the whole report runs on a bare host -----------------------------------------

# Every path below is absent and no service manager is present: the report is a
# diagnostic tool and must never be the thing that fails.
#
# This runs in its own shell rather than a subshell. Bash suppresses errexit
# inside a subshell that forms part of an || list, so a command that aborts the
# report would go unnoticed here; a separate process keeps set -e in force and
# surfaces the failure as a non-zero exit status.
bare_host_status=0
bash -c '
  set -euo pipefail
  root="$1"; scratch="$2"
  source "${root}/include/common.sh"
  source "${root}/include/php.sh"
  source "${root}/include/logrotate.sh"
  source "${root}/include/fail2ban.sh"
  source "${root}/include/vhost_lib.sh"
  source "${root}/include/status_report.sh"
  timezone=UTC
  wwwroot_dir="${scratch}/gone"; logs_dir="${scratch}/gone"; backup_dir="${scratch}/gone"
  runtime_base_dir="${scratch}/gone"; LNMP_SRC_DIR="${scratch}/gone"
  nginx_install_dir="${scratch}/gone"; php_install_base="${scratch}/gone"
  mysql_install_dir="${scratch}/gone"; mariadb_install_dir="${scratch}/gone"
  redis_install_dir="${scratch}/gone"; memcached_install_dir="${scratch}/gone"
  composer_install_dir="${scratch}/gone"
  command_exists() { return 1; }
  print_status_report
' _ "${ROOT_DIR}" "${tmp_dir}" >/dev/null 2>&1 || bare_host_status=$?
((bare_host_status == 0)) ||
  fail "the status report should survive a host where nothing is installed (exit ${bare_host_status})"

echo "PASS: status report"
