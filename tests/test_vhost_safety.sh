#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/vhost_lib.sh"

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

nginx_install_dir="${tmp_dir}/nginx"
wwwroot_dir="${tmp_dir}/wwwroot"
nginx_log_dir="${tmp_dir}/logs/nginx"
nginx_http_port=80
nginx_https_port=443
user=stackpilot
group=stackpilot
mkdir -p "$(vhost_conf_dir)" "${wwwroot_dir}" "${nginx_log_dir}"

# --- existing-site detection --------------------------------------------------

if vhost_exists "absent.test"; then fail "an unknown domain should not be reported as existing"; fi
render_vhost_http "plain.test" "" "${wwwroot_dir}/plain.test" "y" "84" "n" "php"
vhost_exists "plain.test" || fail "a rendered domain should be reported as existing"
if vhost_has_ssl "plain.test"; then fail "an HTTP-only vhost should not be reported as serving TLS"; fi

render_vhost_ssl "tls.test" "" "${wwwroot_dir}/tls.test" "y" "84" "y" "php"
vhost_has_ssl "tls.test" || fail "an SSL vhost should be reported as serving TLS"

# The recorded web root must be returned whole. Taking only the first
# whitespace-separated token truncates a hand-edited path and previously fed a
# wrong directory to rm -rf.
printf 'server {\n    root /srv/my site;\n}\n' > "$(vhost_conf_file "spaced.test")"
assert_eq "/srv/my site" "$(vhost_configured_root "spaced.test")" \
  "the configured web root should be returned without truncation"
assert_eq "${wwwroot_dir}/plain.test" "$(vhost_configured_root "plain.test")" \
  "the configured web root should be read from the rendered config"
if vhost_configured_root "absent.test" >/dev/null 2>&1; then
  fail "an absent config should not yield a web root"
fi

# --- docroot ownership --------------------------------------------------------

chown_log="${tmp_dir}/chown.log"
new_root="${wwwroot_dir}/owned.test"
(
  id() { [[ "$1" == "stackpilot" ]]; }
  chown() { printf '%s\n' "$*" >> "${chown_log}"; }
  prepare_vhost_docroot "${new_root}" "owned.test"
)
[[ -f "${new_root}/index.html" ]] || fail "a new web root should get a placeholder index.html"
assert_eq "-R stackpilot:stackpilot ${new_root}" "$(cat "${chown_log}")" \
  "a newly created web root should be handed to the service account"

# An existing tree may hold a deployed application; its ownership and content
# must be left alone.
: > "${chown_log}"
existing_root="${wwwroot_dir}/deployed.test"
mkdir -p "${existing_root}"
printf 'real application\n' > "${existing_root}/index.html"
(
  id() { return 0; }
  chown() { printf '%s\n' "$*" >> "${chown_log}"; }
  prepare_vhost_docroot "${existing_root}" "deployed.test"
)
assert_eq "" "$(cat "${chown_log}")" "an existing web root must not be re-owned"
assert_eq "real application" "$(cat "${existing_root}/index.html")" \
  "an existing web root must not have its index.html replaced"

# A missing service user is reported rather than silently skipped.
missing_user_warning="$(
  id() { return 1; }
  chown() { :; }
  prepare_vhost_docroot "${wwwroot_dir}/nouser.test" "nouser.test" 2>&1 >/dev/null
)"
[[ "${missing_user_warning}" == *"stackpilot"* ]] || fail "a missing service user should be reported"

# A Laravel or ThinkPHP document root is <site>/public, while storage/,
# bootstrap/cache/, and runtime/ are siblings of it under <site>. Handing over
# only the document root leaves the framework unable to write, which is the
# whole point of the ownership change.
assert_eq "${wwwroot_dir}/laravel.test" "$(vhost_ownership_root "${wwwroot_dir}/laravel.test/public")" \
  "ownership should apply to the site directory, not only the document root"
assert_eq "${wwwroot_dir}/deep.test" "$(vhost_ownership_root "${wwwroot_dir}/deep.test/a/b/c")" \
  "ownership should stop at the first component below the web root"
assert_eq "${wwwroot_dir}/plain.test" "$(vhost_ownership_root "${wwwroot_dir}/plain.test")" \
  "a document root that is already the site directory should be unchanged"
assert_eq "/srv/elsewhere" "$(vhost_ownership_root "/srv/elsewhere")" \
  "a root outside the web root should own only itself"

: > "${chown_log}"
(
  id() { return 0; }
  chown() { printf '%s\n' "$*" >> "${chown_log}"; }
  prepare_vhost_docroot "${wwwroot_dir}/laravel.test/public" "laravel.test"
)
assert_eq "-R stackpilot:stackpilot ${wwwroot_dir}/laravel.test" "$(cat "${chown_log}")" \
  "a new Laravel site should hand over the app directory so storage/ is writable"
[[ -f "${wwwroot_dir}/laravel.test/public/index.html" ]] ||
  fail "the document root should still get its placeholder page"

# When the site already exists, only a document root created here is handed
# over: the rest of the tree may be a deployed application.
: > "${chown_log}"
mkdir -p "${wwwroot_dir}/deployed-app.test/storage"
(
  id() { return 0; }
  chown() { printf '%s\n' "$*" >> "${chown_log}"; }
  prepare_vhost_docroot "${wwwroot_dir}/deployed-app.test/public" "deployed-app.test"
)
assert_eq "-R stackpilot:stackpilot ${wwwroot_dir}/deployed-app.test/public" "$(cat "${chown_log}")" \
  "an existing site should only have the new document root re-owned"

# --- PHP version switching ----------------------------------------------------

switch_root="${wwwroot_dir}/switch.test"
render_vhost_http "switch.test" "" "${switch_root}" "y" "84" "n" "php"
switch_conf="$(vhost_conf_file "switch.test")"
grep -q "fastcgi_pass 127.0.0.1:9084;" "${switch_conf}" || fail "the initial PHP handler should be present"

switch_vhost_php_version "switch.test" "82" >/dev/null
grep -q "fastcgi_pass 127.0.0.1:9082;" "${switch_conf}" || fail "the PHP handler should be rewritten"
[[ ! -e "${switch_conf}.bak" ]] || fail "no .conf.bak should be left in the vhost directory"
compgen -G "$(vhost_conf_dir)/*.bak" >/dev/null && fail "no backup files should remain in the vhost directory"

# Re-running is a no-op rather than a false "switched" report.
switch_vhost_php_version "switch.test" "82" >/dev/null
grep -q "fastcgi_pass 127.0.0.1:9082;" "${switch_conf}" || fail "an idempotent switch should keep the handler"

# A static site has no PHP handler, so the switch must fail loudly instead of
# reporting success after changing nothing.
render_vhost_http "static.test" "" "${wwwroot_dir}/static.test" "n" "84" "n" "static"
if ( switch_vhost_php_version "static.test" "82" ) >/dev/null 2>&1; then
  fail "switching PHP on a site without a PHP handler should fail"
fi

# --- certificate lineage ------------------------------------------------------

LNMP_LETSENCRYPT_LIVE_DIR="${tmp_dir}/letsencrypt/live"
mkdir -p "${LNMP_LETSENCRYPT_LIVE_DIR}/lineage.test"
printf 'chain\n' > "${LNMP_LETSENCRYPT_LIVE_DIR}/lineage.test/fullchain.pem"
printf 'key\n' > "${LNMP_LETSENCRYPT_LIVE_DIR}/lineage.test/privkey.pem"
link_ssl_certificate "lineage.test"
assert_eq "${LNMP_LETSENCRYPT_LIVE_DIR}/lineage.test/fullchain.pem" \
  "$(readlink "$(ssl_cert_dir "lineage.test")/fullchain.pem")" \
  "the exact lineage should be linked when it exists"

# Certbot appends -0001 when an earlier run created a lineage without
# --cert-name; the suffixed directory must still be found.
mkdir -p "${LNMP_LETSENCRYPT_LIVE_DIR}/suffixed.test-0001"
printf 'chain\n' > "${LNMP_LETSENCRYPT_LIVE_DIR}/suffixed.test-0001/fullchain.pem"
printf 'key\n' > "${LNMP_LETSENCRYPT_LIVE_DIR}/suffixed.test-0001/privkey.pem"
link_ssl_certificate "suffixed.test"
assert_eq "${LNMP_LETSENCRYPT_LIVE_DIR}/suffixed.test-0001/fullchain.pem" \
  "$(readlink "$(ssl_cert_dir "suffixed.test")/fullchain.pem")" \
  "a suffixed lineage should be found when the exact name is absent"

if (link_ssl_certificate "nocert.test") >/dev/null 2>&1; then
  fail "linking a certificate that does not exist should fail"
fi

# --- certbot invocation and rate limits --------------------------------------

certbot_args_log="${tmp_dir}/certbot-args.log"
cert_root="${wwwroot_dir}/cert.test"
mkdir -p "${cert_root}" "${LNMP_LETSENCRYPT_LIVE_DIR}/cert.test"
printf 'chain\n' > "${LNMP_LETSENCRYPT_LIVE_DIR}/cert.test/fullchain.pem"
printf 'key\n' > "${LNMP_LETSENCRYPT_LIVE_DIR}/cert.test/privkey.pem"
(
  command_exists() { [[ "$1" == "certbot" ]]; }
  certbot() { printf '%s\n' "$*" > "${certbot_args_log}"; }
  LNMP_SKIP_SSL_PREFLIGHT=1
  issue_ssl_certificate "cert.test" "www.cert.test" "${cert_root}" "ops@cert.test"
) >/dev/null || fail "a successful certbot run should succeed"

certbot_args="$(cat "${certbot_args_log}")"
[[ "${certbot_args}" == *"--cert-name cert.test"* ]] || fail "certbot should pin the lineage with --cert-name"
[[ "${certbot_args}" == *"--keep-until-expiring"* ]] || fail "certbot should reuse a still-valid certificate"
[[ "${certbot_args}" == *"--expand"* ]] || fail "certbot should expand the lineage when the domain set changes"
[[ "${certbot_args}" == *"-d cert.test"* && "${certbot_args}" == *"-d www.cert.test"* ]] ||
  fail "certbot should request the domain and its aliases"

# Rate limit with an existing certificate: reuse it rather than failing.
rate_limited_output="$(
  command_exists() { [[ "$1" == "certbot" ]]; }
  certbot() { echo "too many certificates already issued for exact set of domains"; return 1; }
  LNMP_SKIP_SSL_PREFLIGHT=1
  issue_ssl_certificate "cert.test" "" "${cert_root}" "ops@cert.test" 2>&1
)" || fail "a rate limit with an existing certificate should still succeed"
[[ "${rate_limited_output}" == *"rate limit"* ]] || fail "a rate limit should be reported: got '${rate_limited_output}'"

# Rate limit with no certificate at all: report failure so the caller keeps the
# working HTTP site instead of rendering an SSL block with no certificate.
if (
  command_exists() { [[ "$1" == "certbot" ]]; }
  certbot() { echo "too many certificates already issued"; return 1; }
  LNMP_SKIP_SSL_PREFLIGHT=1
  issue_ssl_certificate "never-issued.test" "" "${cert_root}" "ops@cert.test"
) >/dev/null 2>&1; then
  fail "a rate limit with no existing certificate should report failure"
fi

# --- menu resilience ----------------------------------------------------------

menu_warning="$(
  failing_action() { die "simulated failure"; }
  run_menu_action "The test action" failing_action 2>&1 >/dev/null
)" || fail "run_menu_action must return success so the menu loop continues"
[[ "${menu_warning}" == *"The test action did not complete"* ]] ||
  fail "a failed menu action should be reported: got '${menu_warning}'"

(
  succeeding_action() { return 0; }
  run_menu_action "The test action" succeeding_action
) >/dev/null || fail "a successful menu action should return success"

# The menu pause must not abort the tool when standard input is closed.
( pause_for_menu </dev/null ) >/dev/null 2>&1 || fail "pause_for_menu should tolerate EOF"

echo "PASS: vhost safety and menu resilience"
