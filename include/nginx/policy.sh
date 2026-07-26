#!/usr/bin/env bash

# HTTP-level policy shared by the main Nginx configuration and by every rendered
# virtual host: request size limits, response security headers, rate limiting,
# and HTTP/3. Both include/nginx.sh and include/vhost_lib.sh source this file.

NGINX_REQ_ZONE="stackpilot_req"
NGINX_CONN_ZONE="stackpilot_conn"

nginx_option_integer() {
  local value="$1" max="$2"
  validate_positive_integer "${value}" "${max}" || return 1
  printf '%s' "$((10#${value}))"
}

# Every value this module interpolates is validated here, before any of it is
# substituted into a configuration file. Checking at the point of use is not
# enough: these emitters run inside $( ) within heredocs, where a die only ends
# the substitution subshell and leaves a silently truncated directive behind
# rather than stopping the run.
assert_nginx_policy_options() {
  nginx_body_size_limit >/dev/null
  [[ "${nginx_hsts_max_age:-31536000}" =~ ^[0-9]{1,10}$ ]] ||
    die "Invalid nginx_hsts_max_age: ${nginx_hsts_max_age} (expected seconds, or 0 to omit HSTS)"
  assert_http3_supported
  nginx_rate_limit_configured || return 0
  validate_positive_integer "${nginx_rate_limit_rps:-10}" 100000 ||
    die "Invalid nginx_rate_limit_rps: ${nginx_rate_limit_rps} (expected an integer from 1 through 100000)"
  validate_positive_integer "${nginx_rate_limit_burst:-20}" 100000 ||
    die "Invalid nginx_rate_limit_burst: ${nginx_rate_limit_burst} (expected an integer from 1 through 100000)"
  validate_positive_integer "${nginx_conn_limit:-20}" 100000 ||
    die "Invalid nginx_conn_limit: ${nginx_conn_limit} (expected an integer from 1 through 100000)"
}

# Nginx rejects a body larger than client_max_body_size before the request ever
# reaches PHP, and its built-in default is 1m. Leaving it unset makes a stack
# that advertises php_upload_max_filesize=50M return 413 for anything above one
# megabyte, so the limit follows post_max_size unless options.conf overrides it.
nginx_body_size_limit() {
  local configured="${nginx_client_max_body_size:-}" normalized
  if [[ -n "${configured}" ]]; then
    normalized="$(normalize_size_value "${configured}")" ||
      die "Invalid nginx_client_max_body_size: ${configured} (use a value such as 64m)"
    printf '%s' "${normalized}"
    return 0
  fi
  if normalized="$(normalize_size_value "${php_post_max_size:-}" 2>/dev/null)"; then
    printf '%s' "${normalized}"
    return 0
  fi
  printf '50m'
}

# Emitted inside a server block. add_header is inherited by every location that
# does not define one of its own, and none of the generated locations do.
#
# Every optional block below starts its lines with a newline rather than ending
# them with one, and is appended to the end of an existing directive line at the
# call site. Command substitution strips trailing newlines, so a block written
# the other way around would run the following directive onto the same line, and
# would leave a stray blank line when the block is empty.
nginx_security_header_lines() {
  local scheme="${1:-http}" max_age
  [[ "${nginx_security_headers:-y}" == "y" ]] || return 0
  printf '\n    add_header X-Content-Type-Options nosniff always;'
  printf '\n    add_header X-Frame-Options SAMEORIGIN always;'
  printf '\n    add_header Referrer-Policy strict-origin-when-cross-origin always;'
  # HSTS is meaningless over plain HTTP and browsers ignore it there.
  [[ "${scheme}" == "https" ]] || return 0
  max_age="${nginx_hsts_max_age:-31536000}"
  [[ "${max_age}" =~ ^[0-9]{1,10}$ ]] || die "Invalid nginx_hsts_max_age: ${max_age}"
  ((10#${max_age} > 0)) || return 0
  printf '\n    add_header Strict-Transport-Security "max-age=%s" always;' "$((10#${max_age}))"
}

nginx_rate_limit_configured() {
  [[ "${nginx_rate_limit:-n}" == "y" ]]
}

# The shared-memory zones are declared in the http block written at install
# time. A virtual host that emits limit_req without them makes `nginx -t` fail,
# which is exactly what would happen to a site added after the option was
# switched on, so the renderer confirms the zone exists rather than trusting the
# flag on its own.
nginx_rate_limit_active() {
  local conf="${nginx_install_dir:-}/conf/nginx.conf"
  nginx_rate_limit_configured || return 1
  [[ -f "${conf}" ]] || return 0
  grep -q "zone=${NGINX_REQ_ZONE}:" "${conf}"
}

nginx_rate_limit_zone_block() {
  local rps
  nginx_rate_limit_configured || return 0
  rps="$(nginx_option_integer "${nginx_rate_limit_rps:-10}" 100000)" ||
    die "Invalid nginx_rate_limit_rps: ${nginx_rate_limit_rps}"
  cat <<EOF

    limit_req_zone \$binary_remote_addr zone=${NGINX_REQ_ZONE}:10m rate=${rps}r/s;
    limit_conn_zone \$binary_remote_addr zone=${NGINX_CONN_ZONE}:10m;
    limit_req_status 429;
    limit_conn_status 429;
EOF
}

# Emitted inside a location block, which is indented one level deeper.
nginx_rate_limit_directives() {
  local burst conn
  nginx_rate_limit_active || return 0
  burst="$(nginx_option_integer "${nginx_rate_limit_burst:-20}" 100000)" ||
    die "Invalid nginx_rate_limit_burst: ${nginx_rate_limit_burst}"
  conn="$(nginx_option_integer "${nginx_conn_limit:-20}" 100000)" ||
    die "Invalid nginx_conn_limit: ${nginx_conn_limit}"
  printf '\n        limit_req zone=%s burst=%s nodelay;' "${NGINX_REQ_ZONE}" "${burst}"
  printf '\n        limit_conn %s %s;' "${NGINX_CONN_ZONE}" "${conn}"
}

nginx_http3_configured() {
  [[ "${nginx_http3:-n}" == "y" ]]
}

# QUIC arrived in Nginx 1.25.0. Older releases have no --with-http_v3_module and
# fail during ./configure if it is passed.
nginx_supports_http3() {
  local version="${1:-${nginx_ver:-}}"
  [[ -n "${version}" ]] || return 1
  [[ "$(compare_versions "${version}" "1.25.0")" != "-1" ]]
}

assert_http3_supported() {
  nginx_http3_configured || return 0
  nginx_supports_http3 "${nginx_ver:-}" ||
    die "nginx_http3=y requires Nginx 1.25.0 or newer, but ${nginx_ver:-unknown} is selected"
}

# reuseport is deliberately omitted: it may appear only once per address across
# the whole configuration, so adding it here would break the second virtual
# host. It is a performance option, not a requirement for QUIC.
nginx_http3_listen_line() {
  nginx_http3_configured || return 0
  printf '\n    listen %s quic;' "${nginx_https_port:-443}"
}

nginx_http3_advertise_header() {
  nginx_http3_configured || return 0
  printf '\n    add_header Alt-Svc '\''h3=":%s"; ma=86400'\'' always;' "${nginx_https_port:-443}"
}
