#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
source "${ROOT_DIR}/include/php_extensions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

component_version_supported "1.26.3" "${nginx_versions}" || fail "curated Nginx version rejected"
if component_version_supported "0.0.0" "${nginx_versions}"; then fail "unknown Nginx version accepted"; fi
assert_eq "8.4.0" "$(normalize_component_version 8.4.0 "${mysql_versions}")" "MySQL version normalization"
if normalize_component_version 9.0.0 "${mysql_versions}" >/dev/null 2>&1; then fail "unknown MySQL version accepted"; fi

nginx_ver=1.26.3
mysql_ver=8.0.42
mariadb_ver=11.4.9
redis_ver=7.2.10
refresh_component_version_urls
assert_eq "https://nginx.org/download/nginx-1.26.3.tar.gz" "${nginx_url}" "Nginx selected URL"
assert_eq "https://download.redis.io/releases/redis-7.2.10.tar.gz" "${redis_url}" "Redis selected URL"
[[ "$(mysql_binary_url)" == *"/MySQL-8.0/mysql-8.0.42-linux-glibc2.17-"* ]] || fail "MySQL 8.0 URL should use its series and ABI"
[[ "$(mariadb_binary_url)" == *"/mariadb-11.4.9/"* ]] || fail "MariaDB URL should use selected version"

php_builtin_extension_supported 72 sodium || fail "PHP 7.2 should support sodium"
if php_builtin_extension_supported 71 sodium; then fail "PHP 7.1 should not enable bundled sodium"; fi
php_builtin_extension_supported 74 ffi || fail "PHP 7.4 should support FFI"
OS_ID=debian
OS_VERSION_ID=12
php_builtin_extension_supported 83 imap || fail "PHP 8.3 should support bundled IMAP when the system dependency exists"
if php_builtin_extension_supported 84 imap; then fail "PHP 8.4 should not configure the unbundled IMAP extension"; fi
OS_VERSION_ID=13
if php_builtin_extension_supported 83 imap; then fail "Debian 13 should skip IMAP because c-client is unavailable"; fi
if php_pecl_extension_supported 56 grpc; then fail "PHP 5.6 should not install modern grpc"; fi
php_pecl_extension_supported 80 grpc || fail "PHP 8.0 should support grpc"
if php_pecl_extension_supported 84 ioncube; then fail "ionCube should remain manual-only"; fi

flags="$(php_configure_flags_for_extensions 84 'bz2 sodium ffi pgsql pdo_pgsql')"
[[ "${flags}" == *"--with-bz2"* ]] || fail "bzip2 configure flag missing"
[[ "${flags}" == *"--with-sodium"* ]] || fail "sodium configure flag missing"
[[ "${flags}" == *"--with-pdo-pgsql"* ]] || fail "PDO PostgreSQL configure flag missing"

echo "PASS: versions and PHP extensions"
