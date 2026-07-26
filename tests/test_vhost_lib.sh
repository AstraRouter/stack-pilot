#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/vhost_lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

nginx_install_dir="${tmp_dir}/nginx"
wwwroot_dir="${tmp_dir}/wwwroot"
nginx_log_dir="${tmp_dir}/logs/nginx"
php_install_base="/usr/local/services/php"
nginx_http_port=80
nginx_https_port=443
mkdir -p "${nginx_install_dir}/conf/vhost" "${wwwroot_dir}" "${nginx_log_dir}"

render_vhost_http "example.com" "www.example.com" "${wwwroot_dir}/example.com" "y" "84" "n"
conf="${nginx_install_dir}/conf/vhost/example.com.conf"
[[ -f "${conf}" ]] || fail "http vhost config not created"
grep -q "server_name example.com www.example.com;" "${conf}" || fail "server_name not rendered"
grep -q "fastcgi_pass 127.0.0.1:9084;" "${conf}" || fail "PHP versioned fastcgi block not rendered"
grep -q "access_log ${nginx_log_dir}/example.com.access.log;" "${conf}" || fail "vhost access log should use nginx_log_dir"
grep -q "location \\^~ /.well-known/acme-challenge/" "${conf}" || fail "ACME challenge location should be rendered"
grep -q "root ${wwwroot_dir}/example.com;" "${conf}" || fail "ACME challenge should use vhost root"

render_vhost_ssl "example.com" "www.example.com" "${wwwroot_dir}/example.com" "y" "84" "y"
grep -q "listen 443 ssl;" "${conf}" || fail "SSL listener not rendered"
grep -q "http2 on;" "${conf}" || fail "HTTP/2 directive not rendered"
grep -q "ssl_certificate ${nginx_install_dir}/conf/ssl/example.com/fullchain.pem;" "${conf}" || fail "SSL certificate should use nginx ssl directory"
grep -q "ssl_certificate_key ${nginx_install_dir}/conf/ssl/example.com/privkey.pem;" "${conf}" || fail "SSL key should use nginx ssl directory"
# Nginx/systemd variables are matched literally; the shell must not expand them.
# shellcheck disable=SC2016
grep -q 'return 301 https://\$host\$request_uri;' "${conf}" || fail "HTTPS redirect not rendered"
grep -q "location \\^~ /.well-known/acme-challenge/" "${conf}" || fail "SSL redirect vhost should keep ACME challenge location"

list_vhosts | grep -q "example.com" || fail "list_vhosts should include created vhost"

delete_vhost_config "example.com"
[[ ! -f "${conf}" ]] || fail "delete_vhost_config did not remove config"

ssl_root="${wwwroot_dir}/ssl.test"
mkdir -p "${ssl_root}"
domain_dns_addresses() {
  printf '203.0.113.10\n'
}
fetch_http_challenge() {
  printf 'stack-pilot:%s' "$2"
}
preflight_ssl_certificate "ssl.test" "www.ssl.test" "${ssl_root}" >/dev/null
[[ ! -d "${ssl_root}/.well-known/acme-challenge" ]] || fail "SSL preflight challenge file should be cleaned"

domain_dns_addresses() {
  return 1
}
if (preflight_ssl_certificate "missing.test" "" "${ssl_root}" >/dev/null 2>&1); then
  fail "SSL preflight must reject a domain without A/AAAA records"
fi

domain_dns_addresses() {
  [[ "$1" != "www.alias-missing.test" ]] || return 1
  printf '203.0.113.10\n'
}
fetch_http_challenge() {
  printf 'stack-pilot:%s' "$2"
}
if (preflight_ssl_certificate "alias-missing.test" "www.alias-missing.test" "${ssl_root}" >/dev/null 2>&1); then
  fail "SSL preflight must reject an unresolved certificate alias"
fi

domain_dns_addresses() {
  printf '203.0.113.10\n'
}
fetch_http_challenge() {
  printf 'unexpected-body'
}
if (preflight_ssl_certificate "wrong-origin.test" "" "${ssl_root}" >/dev/null 2>&1); then
  fail "SSL preflight must reject an unreachable or incorrect webroot response"
fi

echo "PASS: vhost library"
