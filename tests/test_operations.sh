#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/php_extensions.sh"
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

LNMP_STATE_DIR="${tmp_dir}/state"
mark_step_done "php:84"
is_step_done "php:84" || fail "state marker should be detected"
is_step_done "php:83" && fail "missing state marker should not be detected"
mark_step_done "nginx:1.28.1"
is_step_done "nginx:1.28.1" || fail "versioned Nginx state marker should be detected"
is_step_done "nginx:1.26.3" && fail "a different Nginx version must not reuse the old state marker"

component_dir="${tmp_dir}/component"
write_component_version_marker "${component_dir}" "1.28.1"
assert_eq "1.28.1" "$(read_component_version_marker "${component_dir}")" "component version marker should round-trip"
assert_eq "8.4.0" "$(printf 'mysqld  Ver 8.4.0 for Linux on x86_64' | extract_semver)" "component version parser"
verify_or_adopt_component_version Nginx "${component_dir}" "1.28.1" ""
if (verify_or_adopt_component_version Nginx "${component_dir}" "1.26.3" "" >/dev/null 2>&1); then
  fail "component version mismatch should be rejected"
fi
should_skip_completed_install Nginx "${component_dir}" "1.28.1" "" || fail "normal install should skip matching completed component"
LNMP_FORCE_REINSTALL=1
if should_skip_completed_install Nginx "${component_dir}" "1.28.1" ""; then
  fail "explicit force reinstall should not skip completed component"
fi
unset LNMP_FORCE_REINSTALL
clear_step_done "nginx:1.28.1"
is_step_done "nginx:1.28.1" && fail "state marker should be clearable for upgrade"

printf 'abc' > "${tmp_dir}/sum.txt"
verify_sha256 "${tmp_dir}/sum.txt" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" || fail "sha256 verification failed"
if verify_sha256 "${tmp_dir}/sum.txt" "bad" 2>/dev/null; then fail "bad sha256 accepted"; fi
printf 'hello {{name}}\n' > "${tmp_dir}/template.tpl"
render_template_file "${tmp_dir}/template.tpl" "${tmp_dir}/rendered.txt" name world
grep -q '^hello world$' "${tmp_dir}/rendered.txt" || fail "template render failed"

assert_eq "redis-4.3.0" "$(php_pecl_package 54 redis)" "PHP 5.4 redis PECL version should be pinned"
assert_eq "xdebug-2.5.5" "$(php_pecl_package 56 xdebug)" "PHP 5.6 xdebug PECL version should be pinned"
assert_eq "swoole-4.8.13" "$(php_pecl_package 74 swoole)" "PHP 7.4 swoole PECL version should be pinned"
assert_eq "redis" "$(php_pecl_package 84 redis)" "PHP 8.4 redis can use current package"

nginx_install_dir="${tmp_dir}/nginx"
nginx_log_dir="${tmp_dir}/logs"
wwwroot_dir="${tmp_dir}/wwwroot"
php_install_base="/usr/local/services/php"
nginx_http_port=80
mkdir -p "${nginx_install_dir}/conf/vhost" "${nginx_log_dir}"
render_vhost_http "laravel.test" "" "${wwwroot_dir}/laravel.test/public" "y" "84" "n" "laravel"
grep -q 'try_files $uri $uri/ /index.php?$query_string;' "${nginx_install_dir}/conf/vhost/laravel.test.conf" || fail "laravel try_files not rendered"
render_vhost_http "think.test" "" "${wwwroot_dir}/think.test/public" "y" "84" "n" "thinkphp"
grep -q 'try_files $uri $uri/ /index.php?s=$uri&$query_string;' "${nginx_install_dir}/conf/vhost/think.test.conf" || fail "thinkphp try_files not rendered"

php_install_base="${tmp_dir}/services/php"
mkdir -p "${php_install_base}/84/bin"
for bin in php phpize php-config pecl pear; do
  printf '#!/usr/bin/env bash\n' > "${php_install_base}/84/bin/${bin}"
  chmod +x "${php_install_base}/84/bin/${bin}"
done
LNMP_CLI_BIN_DIR="${tmp_dir}/bin"
switch_cli_php_version 84
[[ -L "${LNMP_CLI_BIN_DIR}/php" ]] || fail "php cli symlink not created"
assert_eq "${php_install_base}/84/bin/php" "$(readlink "${LNMP_CLI_BIN_DIR}/php")" "php cli symlink target incorrect"
assert_eq "${php_install_base}/84/bin/phpize" "$(readlink "${LNMP_CLI_BIN_DIR}/phpize")" "phpize cli symlink target incorrect"
mkdir -p "${tmp_dir}/services/nginx/sbin"
printf '#!/usr/bin/env bash\n' > "${tmp_dir}/services/nginx/sbin/nginx"
chmod +x "${tmp_dir}/services/nginx/sbin/nginx"
link_executable_to_bin "${tmp_dir}/services/nginx/sbin/nginx" nginx
assert_eq "${tmp_dir}/services/nginx/sbin/nginx" "$(readlink "${LNMP_CLI_BIN_DIR}/nginx")" "nginx cli symlink target incorrect"

echo "PASS: operations helpers"
