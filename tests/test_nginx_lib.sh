#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/nginx.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

LNMP_SYSTEMD_UNIT_DIR="${tmp_dir}/systemd"
nginx_install_dir="${tmp_dir}/nginx"
nginx_pid="${tmp_dir}/nginx.pid"
mkdir -p "${nginx_install_dir}/sbin"

write_nginx_service
unit="${LNMP_SYSTEMD_UNIT_DIR}/nginx.service"

grep -q '^Type=simple$' "${unit}" || fail "Nginx unit should use Type=simple"
grep -q 'nginx -g "daemon off;"$' "${unit}" || fail "Nginx should run in foreground under systemd"
# Nginx/systemd variables are matched literally; the shell must not expand them.
# shellcheck disable=SC2016
grep -q '^ExecReload=/bin/kill -HUP \$MAINPID$' "${unit}" || fail "Nginx reload should signal systemd main PID"
# Nginx/systemd variables are matched literally; the shell must not expand them.
# shellcheck disable=SC2016
grep -q '^ExecStop=/bin/kill -QUIT \$MAINPID$' "${unit}" || fail "Nginx stop should signal systemd main PID"
if grep -q '^PIDFile=' "${unit}"; then fail "foreground Nginx unit must not depend on PIDFile"; fi
grep -q '^Restart=on-failure$' "${unit}" || fail "Nginx unit should restart after unexpected failure"

# --- request size limit -------------------------------------------------------

# Nginx returns 413 before PHP is reached, and its own default is 1m, so leaving
# this unset silently caps uploads far below php_upload_max_filesize.
assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_eq "50m" "$(php_post_max_size=50M nginx_client_max_body_size='' nginx_body_size_limit)" \
  "the body limit should follow php_post_max_size"
assert_eq "128m" "$(php_post_max_size=50M nginx_client_max_body_size=128M nginx_body_size_limit)" \
  "an explicit nginx_client_max_body_size should win"
assert_eq "2g" "$(php_post_max_size=2G nginx_client_max_body_size='' nginx_body_size_limit)" \
  "gigabyte sizes should normalize"
assert_eq "50m" "$(php_post_max_size='' nginx_client_max_body_size='' nginx_body_size_limit)" \
  "an unset post_max_size should still produce a usable default"
if (nginx_client_max_body_size='50M; root /etc' nginx_body_size_limit) >/dev/null 2>&1; then
  fail "an injected size value should abort rather than reach nginx.conf"
fi

# --- main configuration -------------------------------------------------------

user=www
group=www
nginx_log_dir="${tmp_dir}/logs"
wwwroot_dir="${tmp_dir}/www"
nginx_http_port=80
php_post_max_size=50M
mkdir -p "${nginx_install_dir}/conf/vhost" "${nginx_log_dir}" "${wwwroot_dir}/default"
write_nginx_main_conf
main_conf="${nginx_install_dir}/conf/nginx.conf"

grep -Eq '^[[:space:]]*client_max_body_size[[:space:]]+50m;' "${main_conf}" ||
  fail "the http block must set client_max_body_size to match PHP"
grep -q 'gzip_types' "${main_conf}" || fail "text assets should be compressed"
if grep -q 'limit_req_zone' "${main_conf}"; then fail "rate limiting must stay off by default"; fi

# An Nginx upgrade re-runs this and must not replace a real landing page.
printf 'my real site\n' > "${wwwroot_dir}/default/index.html"
write_nginx_main_conf
grep -q 'my real site' "${wwwroot_dir}/default/index.html" ||
  fail "rewriting the configuration must not overwrite an existing default page"

# A hostile or broken options.conf must not reach nginx.conf.
for bad in "www www; root /etc" "" "root/../etc" "UPPER"; do
  if (user="${bad}" write_nginx_main_conf) >/dev/null 2>&1; then
    fail "service user '${bad}' should be rejected before nginx.conf is written"
  fi
done
if (nginx_worker_connections="1024; user root" write_nginx_main_conf) >/dev/null 2>&1; then
  fail "an injected worker_connections value should be rejected"
fi

# --- rate limiting ------------------------------------------------------------

(
  nginx_rate_limit=y
  nginx_rate_limit_rps=25
  write_nginx_main_conf
)
grep -q 'limit_req_zone .* zone=stackpilot_req:10m rate=25r/s;' "${main_conf}" ||
  fail "enabling rate limiting should declare the request zone"
grep -q 'limit_conn_zone .* zone=stackpilot_conn:10m;' "${main_conf}" ||
  fail "enabling rate limiting should declare the connection zone"

# A vhost that emits limit_req without the zone makes nginx -t fail, so the
# renderer confirms the zone exists rather than trusting the flag.
assert_eq "" "$(nginx_rate_limit=n nginx_rate_limit_directives)" \
  "rate-limit directives should be absent when the option is off"
[[ -n "$(nginx_rate_limit=y nginx_rate_limit_directives)" ]] ||
  fail "rate-limit directives should be emitted once the zone is declared"
: > "${main_conf}"
assert_eq "" "$(nginx_rate_limit=y nginx_rate_limit_directives)" \
  "rate-limit directives must not be emitted when nginx.conf has no matching zone"

# --- security headers ---------------------------------------------------------

headers="$(nginx_security_header_lines http)"
[[ "${headers}" == *"X-Content-Type-Options nosniff"* ]] || fail "nosniff header missing"
[[ "${headers}" == *"X-Frame-Options"* ]] || fail "X-Frame-Options header missing"
if [[ "${headers}" == *"Strict-Transport-Security"* ]]; then
  fail "HSTS is ignored over plain HTTP and must not be sent there"
fi
tls_headers="$(nginx_security_header_lines https)"
[[ "${tls_headers}" == *"Strict-Transport-Security \"max-age=31536000\" always;"* ]] ||
  fail "HTTPS server blocks should send HSTS"
assert_eq "" "$(nginx_security_headers=n nginx_security_header_lines https)" \
  "security headers should be suppressible"
if [[ "$(nginx_hsts_max_age=0 nginx_security_header_lines https)" == *"Strict-Transport-Security"* ]]; then
  fail "nginx_hsts_max_age=0 should omit HSTS entirely"
fi

# --- HTTP/3 -------------------------------------------------------------------

nginx_supports_http3 1.28.1 || fail "Nginx 1.28.1 supports QUIC"
nginx_supports_http3 1.25.0 || fail "QUIC support starts at 1.25.0"
if nginx_supports_http3 1.24.0; then fail "Nginx 1.24 has no http_v3 module"; fi
assert_eq "" "$(nginx_http3=n nginx_configure_extra_flags)" "HTTP/3 must stay opt-in"
assert_eq "--with-http_v3_module" "$(nginx_http3=y nginx_configure_extra_flags)" \
  "enabling HTTP/3 should add the build flag"
if (nginx_http3=y nginx_ver=1.24.0 assert_http3_supported) >/dev/null 2>&1; then
  fail "requesting HTTP/3 on a version without QUIC should abort before the build"
fi
# reuseport may appear only once per address in the whole configuration, so a
# per-vhost listen line carrying it would break the second site.
if [[ "$(nginx_http3=y nginx_https_port=443 nginx_http3_listen_line)" == *reuseport* ]]; then
  fail "the QUIC listen line must not carry reuseport"
fi

echo "PASS: nginx service helpers"
