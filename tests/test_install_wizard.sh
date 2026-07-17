#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/install/wizard.sh"
source "${ROOT_DIR}/include/php_extensions.sh"

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

directory_prompt_pattern='prompt_input "(Program installation root|Data root|Runtime root|PID directory|Socket directory|Log root|.*installation directory|.*installation base|.*data directory|.*log directory|.*PID file|.*socket file|Web root)"'
if grep -Eq "${directory_prompt_pattern}" "${ROOT_DIR}/install.sh"; then
  fail "install.sh should not ask for directory/path values during install"
fi

OS_ID=ubuntu
OS_VERSION_ID=25
assert_eq "libaio1t64" "$(apt_libaio_package)" "Ubuntu 25 should use t64 libaio package"

OS_ID=ubuntu
OS_VERSION_ID=22
assert_eq "libaio1" "$(apt_libaio_package)" "Ubuntu 22 should keep legacy libaio package"

install_components="nginx mysql redis"
db_engine=mysql
nginx_http_port=80
nginx_https_port=443
mysql_port=3306
redis_port=6379
memcached_port=11211
validate_selected_service_ports || fail "default selected service ports should be valid"
redis_port=3306
if validate_selected_service_ports >/dev/null 2>&1; then fail "duplicate selected service ports should be rejected"; fi
redis_port=70000
if validate_selected_service_ports >/dev/null 2>&1; then fail "out-of-range selected service port should be rejected"; fi

assert_eq "opcache mysqli pdo_mysql mbstring curl openssl" "$(php_profile_builtin_extensions minimal)" "minimal profile extensions"
assert_eq "redis imagick" "$(php_profile_pecl_extensions web)" "web profile should keep only broadly useful PECL defaults"
web_builtin=" $(php_profile_builtin_extensions web) "
[[ "${web_builtin}" != *" soap "* ]] || fail "web profile should not select SOAP by default"
[[ "${web_builtin}" != *" readline "* ]] || fail "web profile should not select readline by default"
full_pecl=" $(php_profile_pecl_extensions full) "
[[ "${full_pecl}" != *" xdebug "* ]] || fail "production-oriented full profile should not enable Xdebug automatically"

echo "PASS: install wizard"
