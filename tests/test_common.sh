#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"

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

pw="$(random_password 24)"
[[ "${#pw}" -eq 24 ]] || fail "random_password should return requested length"
[[ "${pw}" =~ ^[A-Za-z0-9]+$ ]] || fail "random_password should be alphanumeric"

validate_domain "example.com" || fail "valid domain rejected"
validate_domain "www.example.co.uk" || fail "valid subdomain rejected"
if validate_domain "-bad.example" 2>/dev/null; then fail "invalid leading hyphen accepted"; fi
if validate_domain "bad_domain.example" 2>/dev/null; then fail "invalid underscore accepted"; fi

validate_password_or_random "" 6 || fail "empty password should be accepted for random generation"
validate_password_or_random "123456" 6 || fail "6-character database password should be accepted"
if validate_password_or_random "12345" 6 2>/dev/null; then fail "5-character database password accepted"; fi
if validate_password_or_random "abc'def" 6 2>/dev/null; then fail "single quote in password accepted"; fi
if validate_password_or_random "abc\\def" 6 2>/dev/null; then fail "backslash in password accepted"; fi

assert_eq "y" "$(normalize_yes_no "" "y")" "empty yes/no should use default"
assert_eq "n" "$(normalize_yes_no "N" "y")" "uppercase N should normalize"
assert_eq "y" "$(normalize_yes_no "yes" "n")" "yes should normalize"

validate_choice "2" "1 2 3" || fail "valid choice rejected"
if validate_choice "4" "1 2 3"; then fail "invalid choice accepted"; fi

assert_eq "600" "$(apt_lock_timeout)" "default APT lock timeout incorrect"
LNMP_APT_LOCK_TIMEOUT=45
assert_eq "45" "$(apt_lock_timeout)" "custom APT lock timeout incorrect"
LNMP_APT_LOCK_TIMEOUT=invalid
assert_eq "600" "$(apt_lock_timeout)" "invalid APT lock timeout should use default"
unset LNMP_APT_LOCK_TIMEOUT
(
  lock_marker="$(mktemp)"
  trap 'rm -f "${lock_marker}"' EXIT
  printf '4321\n' > "${lock_marker}"
  apt_lock_holder_pids() { [[ -s "${lock_marker}" ]] && printf '4321\n'; }
  sleep() { : > "${lock_marker}"; }
  info() { :; }
  LNMP_APT_LOCK_TIMEOUT=5
  LNMP_APT_LOCK_POLL_INTERVAL=1
  wait_for_apt_locks || fail "APT lock wait should continue after the holder exits"
)
if (
  apt_lock_holder_pids() { printf '9876\n'; }
  warn() { :; }
  LNMP_APT_LOCK_TIMEOUT=0
  wait_for_apt_locks
) >/dev/null 2>&1; then
  fail "APT lock wait should fail after timeout"
fi

assert_eq "1" "$(select_default_index "mysql" "none|Do not install" "mysql|MySQL" "mariadb|MariaDB")" "select default index incorrect"
assert_eq "0" "$(select_default_index "missing" "none|Do not install" "mysql|MySQL")" "missing select default should use first option"
assert_eq "54 85" "$(toggle_multi_value "54" "85")" "toggle should append missing value"
assert_eq "85" "$(toggle_multi_value "54 85" "54")" "toggle should remove existing value"
assert_eq "85" "$(toggle_multi_value "85 54" "54")" "toggle should preserve order after remove"

assert_eq "54 74 85" "$(normalize_php_versions "5.4 7.4 8.5")" "PHP dotted versions not normalized"
assert_eq "54 84" "$(normalize_php_versions "54,84")" "PHP comma-separated versions not normalized"
if normalize_php_versions "5.3" >/dev/null 2>&1; then fail "unsupported PHP 5.3 accepted"; fi
assert_eq "nginx php redis" "$(normalize_values "nginx,php redis" "nginx php mysql mariadb redis")" "generic values not normalized"
if normalize_values "nginx unknown" "nginx php" >/dev/null 2>&1; then fail "unknown generic value accepted"; fi
validate_port 1 || fail "lowest TCP port should be valid"
validate_port 65535 || fail "highest TCP port should be valid"
assert_eq "80" "$((10#$(printf '080')))" "leading-zero port should normalize as decimal"
if validate_port 0; then fail "port zero accepted"; fi
if validate_port 65536; then fail "port above 65535 accepted"; fi
if validate_port abc; then fail "non-numeric port accepted"; fi
assert_eq "9054" "$(php_fpm_port 54)" "PHP 5.4 FPM port incorrect"
assert_eq "9085" "$(php_fpm_port 85)" "PHP 8.5 FPM port incorrect"
php_install_base=/usr/local/services/php
assert_eq "/usr/local/services/php/84" "$(php_install_dir_for_version 84)" "PHP install dir should use version subdirectory"

OS_ID=ubuntu
OS_VERSION_ID=25
install_components="nginx php mysql redis"
db_engine=mysql
php_extensions="opcache mysqli pdo_mysql mbstring curl openssl gd zip fileinfo exif intl bcmath sockets pcntl bz2 sodium"
php_pecl_extensions="redis imagick"
apt_deps=" $(apt_build_dependency_packages | tr '\n' ' ') "
[[ "${apt_deps}" == *" libicu-dev "* ]] || fail "apt build dependencies should include libicu-dev for PHP intl"
[[ "${apt_deps}" == *" libmagickwand-dev "* ]] || fail "apt build dependencies should include libmagickwand-dev for PECL imagick"
[[ "${apt_deps}" != *" libmemcached-dev "* ]] || fail "web profile should not require unselected PECL memcached dependencies"
for matrix_version in 22 23 24 25 26; do
  supported_os_version ubuntu "${matrix_version}" || fail "Ubuntu ${matrix_version} should be supported"
done
for matrix_version in 11 12 13; do
  supported_os_version debian "${matrix_version}" || fail "Debian ${matrix_version} should be supported"
done
for matrix_version in 7 8 9 10; do
  supported_os_version centos "${matrix_version}" || fail "CentOS ${matrix_version} should be supported"
done
if supported_os_version ubuntu 21; then fail "Ubuntu 21 should be rejected"; fi
if supported_os_version ubuntu 27; then fail "Ubuntu 27 should be rejected"; fi
if supported_os_version debian 10; then fail "Debian 10 should be rejected"; fi
if supported_os_version debian 14; then fail "Debian 14 should be rejected"; fi
if supported_os_version centos 6; then fail "CentOS 6 should be rejected"; fi
if supported_os_version centos 11; then fail "CentOS 11 should be rejected"; fi
OS_ID=ubuntu
OS_VERSION_ID=22
apt_deps_ubuntu_22=" $(apt_build_dependency_packages | tr '\n' ' ') "
[[ "${apt_deps_ubuntu_22}" == *" libpcre3-dev "* ]] || fail "Ubuntu 22 should use PCRE3"
[[ "${apt_deps_ubuntu_22}" == *" libfreetype6-dev "* ]] || fail "Ubuntu 22 should use legacy FreeType package"
assert_eq "libaio1" "$(apt_libaio_package)" "Ubuntu 22 libaio mapping incorrect"
OS_ID=ubuntu
OS_VERSION_ID=24
assert_eq "libaio1t64" "$(apt_libaio_package)" "Ubuntu 24 libaio mapping incorrect"
OS_ID=ubuntu
OS_VERSION_ID=26
if php_imap_build_supported_for_system; then fail "Ubuntu 26 should skip the unavailable legacy IMAP build dependency"; fi
apt_deps_ubuntu_26=" $(apt_build_dependency_packages | tr '\n' ' ') "
[[ "${apt_deps_ubuntu_26}" == *" libpcre2-dev "* ]] || fail "Ubuntu 26 should use installable PCRE2 development package"
[[ "${apt_deps_ubuntu_26}" != *" libpcre3-dev "* ]] || fail "Ubuntu 26 should not use obsolete libpcre3-dev package"
[[ "${apt_deps_ubuntu_26}" == *" libfreetype-dev "* ]] || fail "Ubuntu 26 should use renamed FreeType development package"
[[ "${apt_deps_ubuntu_26}" != *" libfreetype6-dev "* ]] || fail "Ubuntu 26 should not require obsolete FreeType package"
OS_ID=debian
OS_VERSION_ID=13
if php_imap_build_supported_for_system; then fail "Debian 13 should skip the unavailable legacy IMAP build dependency"; fi
apt_deps_debian_13=" $(apt_build_dependency_packages | tr '\n' ' ') "
[[ "${apt_deps_debian_13}" == *" libpcre2-dev "* ]] || fail "Debian 13 should use PCRE2"
[[ "${apt_deps_debian_13}" == *" libfreetype-dev "* ]] || fail "Debian 13 should use renamed FreeType package"
for matrix_version in 11 12; do
  OS_ID=debian
  OS_VERSION_ID="${matrix_version}"
  apt_deps_debian_legacy=" $(apt_build_dependency_packages | tr '\n' ' ') "
  [[ "${apt_deps_debian_legacy}" == *" libpcre3-dev "* ]] || fail "Debian ${matrix_version} should use PCRE3"
  [[ "${apt_deps_debian_legacy}" == *" libfreetype6-dev "* ]] || fail "Debian ${matrix_version} should use legacy FreeType package"
  assert_eq "libaio1" "$(apt_libaio_package)" "Debian ${matrix_version} libaio mapping incorrect"
done
OS_ID=centos
OS_VERSION_ID=7
assert_eq "pkgconfig" "$(rpm_pkgconfig_package)" "CentOS 7 pkg-config mapping incorrect"
assert_eq "zlib-devel" "$(rpm_zlib_dev_package)" "CentOS 7 zlib mapping incorrect"
assert_eq "pcre-devel" "$(rpm_pcre_dev_package)" "CentOS 7 PCRE mapping incorrect"
assert_eq "libjpeg-turbo-devel" "$(rpm_jpeg_dev_package)" "CentOS 7 JPEG mapping incorrect"
assert_eq "libmemcached-devel" "$(rpm_libmemcached_dev_package)" "CentOS 7 libmemcached mapping incorrect"
assert_eq "" "$(rpm_devel_repository)" "CentOS 7 should not enable a devel repository"
OS_ID=centos
OS_VERSION_ID=8
assert_eq "pkgconf-pkg-config" "$(rpm_pkgconfig_package)" "CentOS 8 pkg-config mapping incorrect"
assert_eq "zlib-devel" "$(rpm_zlib_dev_package)" "CentOS 8 zlib mapping incorrect"
assert_eq "pcre2-devel" "$(rpm_pcre_dev_package)" "CentOS 8 PCRE mapping incorrect"
assert_eq "libjpeg-turbo-devel" "$(rpm_jpeg_dev_package)" "CentOS 8 JPEG mapping incorrect"
assert_eq "libmemcached-devel" "$(rpm_libmemcached_dev_package)" "CentOS 8 libmemcached mapping incorrect"
assert_eq "powertools" "$(rpm_devel_repository)" "CentOS 8 devel repository incorrect"
OS_ID=centos
OS_VERSION_ID=9
assert_eq "pkgconf-pkg-config" "$(rpm_pkgconfig_package)" "CentOS 9 pkg-config mapping incorrect"
assert_eq "zlib-devel" "$(rpm_zlib_dev_package)" "CentOS 9 zlib mapping incorrect"
assert_eq "pcre2-devel" "$(rpm_pcre_dev_package)" "CentOS 9 PCRE mapping incorrect"
assert_eq "libjpeg-turbo-devel" "$(rpm_jpeg_dev_package)" "CentOS 9 JPEG mapping incorrect"
assert_eq "libmemcached-devel" "$(rpm_libmemcached_dev_package)" "CentOS 9 libmemcached mapping incorrect"
assert_eq "crb" "$(rpm_devel_repository)" "CentOS 9 devel repository incorrect"
OS_ID=centos
OS_VERSION_ID=10
if php_imap_build_supported_for_system; then fail "CentOS 10 should skip the unavailable legacy IMAP build dependency"; fi
rpm_deps=" $(rpm_build_dependency_packages | tr '\n' ' ') "
[[ "${rpm_deps}" == *" libicu-devel "* ]] || fail "rpm build dependencies should include libicu-devel for PHP intl"
[[ "${rpm_deps}" == *" ImageMagick-devel "* ]] || fail "rpm build dependencies should include ImageMagick-devel for PECL imagick"
[[ "${rpm_deps}" == *" pkgconf-pkg-config "* ]] || fail "CentOS 10 should use pkgconf-pkg-config"
[[ "${rpm_deps}" == *" zlib-ng-compat-devel "* ]] || fail "CentOS 10 should use zlib-ng compatibility headers"
[[ "${rpm_deps}" == *" pcre2-devel "* ]] || fail "CentOS 10 should use PCRE2 headers"
[[ "${rpm_deps}" == *" libjpeg-turbo-devel "* ]] || fail "CentOS 10 should use libjpeg-turbo headers"
[[ "${rpm_deps}" != *" libmemcached-devel "* ]] || fail "unselected memcached should not block CentOS web profile"
assert_eq "crb" "$(rpm_devel_repository)" "CentOS 10 devel repository incorrect"
assert_eq "libmemcached-awesome-devel" "$(rpm_libmemcached_dev_package)" "CentOS 10 libmemcached mapping incorrect"
(
  repository_log="$(mktemp)"
  trap 'rm -f "${repository_log}"' EXIT
  PM=dnf
  OS_ID=centos
  OS_VERSION_ID=9
  install_components="php"
  LNMP_PACKAGE_REPOSITORIES_PREPARED=0
  rpm_config_manager_available() { return 0; }
  rpm_repository_disabled() { [[ "$1" == "crb" ]]; }
  rpm_enable_repository() { printf '%s\n' "$1" >> "${repository_log}"; }
  rpm() { return 0; }
  info() { :; }
  prepare_package_repositories
  assert_eq "crb" "$(xargs < "${repository_log}")" "CentOS 9 should enable CRB before dependency preflight"
  assert_eq "1" "${LNMP_PACKAGE_REPOSITORIES_PREPARED}" "repository preparation should be idempotent"
)
php_pecl_extensions="redis imagick memcached rdkafka"
rpm_full_pecl_deps=" $(rpm_build_dependency_packages | tr '\n' ' ') "
[[ "${rpm_full_pecl_deps}" == *" libmemcached-awesome-devel "* ]] || fail "selected memcached should add the CentOS 10 RPM dependency"
[[ "${rpm_full_pecl_deps}" == *" librdkafka-devel "* ]] || fail "selected rdkafka should add its RPM dependency"
php_pecl_extensions="redis imagick"
PM=apt-get
all_deps=" $(system_dependency_packages | tr '\n' ' ') "
[[ "${all_deps}" == *" libicu-dev "* ]] || fail "system dependency list should use package manager specific dependencies"
LNMP_AVAILABLE_PACKAGES="foo bar"
missing_deps="$(missing_dependency_packages foo baz bar | xargs)"
assert_eq "baz" "${missing_deps}" "dependency preflight should report unavailable packages"
unset LNMP_AVAILABLE_PACKAGES
fake_bin="$(mktemp -d)"
old_path="${PATH}"
cat > "${fake_bin}/apt-cache" <<'EOF'
#!/usr/bin/env bash
case "$1:$2" in
  policy:installable)
    printf 'installable:\n  Installed: (none)\n  Candidate: 1.0\n'
    ;;
  policy:missing-candidate)
    printf 'missing-candidate:\n  Installed: (none)\n  Candidate: (none)\n'
    ;;
  show:missing-candidate)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "${fake_bin}/apt-cache"
PATH="${fake_bin}:${PATH}"
PM=apt-get
package_available installable || fail "apt package with candidate should be available"
if package_available missing-candidate; then fail "apt package without installation candidate should not be available"; fi
PATH="${old_path}"
rm -rf "${fake_bin}"
cache_dir="$(mktemp -d)"
LNMP_SRC_DIR="${cache_dir}"
assert_eq "not downloaded" "$(source_cache_state "https://example.com/example.tar.gz")" "missing source archive should be reported"
printf 'cached\n' > "${cache_dir}/example.tar.gz"
assert_eq "downloaded" "$(source_cache_state "https://example.com/example.tar.gz")" "existing source archive should be reported"
rm -rf "${cache_dir}"
ports=""
ports="$(port_list_add_unique "${ports}" 80)"
ports="$(port_list_add_unique "${ports}" 3306)"
ports="$(port_list_add_unique "${ports}" 3306)"
ports="$(port_list_add_unique "${ports}" 6379)"
assert_eq "80 3306 6379" "${ports}" "preflight port list should be unique"

legacy_user_key="run_""user"
legacy_group_key="run_""group"
legacy_suffix="root_""password"
legacy_mysql_key="mysql_${legacy_suffix}"
legacy_mariadb_key="mariadb_${legacy_suffix}"
if grep -Eq "^(${legacy_user_key}|${legacy_group_key}|${legacy_mysql_key}|${legacy_mariadb_key})=" "${ROOT_DIR}/options.example.conf"; then
  fail "options.example.conf should use user/group/mysql_password/mariadb_password naming"
fi
grep -q '^user=' "${ROOT_DIR}/options.example.conf" || fail "options.example.conf should define user"
grep -q '^group=' "${ROOT_DIR}/options.example.conf" || fail "options.example.conf should define group"
grep -q '^mysql_password=$' "${ROOT_DIR}/options.example.conf" || fail "example MySQL password must be empty"
grep -q '^mariadb_password=$' "${ROOT_DIR}/options.example.conf" || fail "example MariaDB password must be empty"
grep -q '^redis_password=$' "${ROOT_DIR}/options.example.conf" || fail "example Redis password must be empty"
source "${ROOT_DIR}/options.example.conf"
[[ -n "${install_components:-}" ]] || fail "install_components should load from options.example.conf"

runtime_config_dir="$(mktemp -d)"
cp "${ROOT_DIR}/options.example.conf" "${runtime_config_dir}/options.example.conf"
LNMP_OPTIONS_EXAMPLE_FILE="${runtime_config_dir}/options.example.conf"
load_options "${runtime_config_dir}/options.conf"
[[ -f "${runtime_config_dir}/options.conf" ]] || fail "load_options should initialize the private runtime config"
runtime_options_mode="$(stat -c '%a' "${runtime_config_dir}/options.conf" 2>/dev/null || stat -f '%Lp' "${runtime_config_dir}/options.conf")"
[[ "${runtime_options_mode}" == "600" ]] || fail "runtime options.conf should use mode 600"
rm -rf "${runtime_config_dir}"
unset LNMP_OPTIONS_EXAMPLE_FILE

tmp_conf="$(mktemp)"
trap 'rm -f "${tmp_conf}"' EXIT
printf 'foo=old\nbar=value\n' > "${tmp_conf}"
set_config_value "${tmp_conf}" "foo" "new value"
set_config_value "${tmp_conf}" "baz" "/tmp/example"
assert_eq "new value" "$(get_config_value "${tmp_conf}" "foo")" "existing config value not updated"
assert_eq "/tmp/example" "$(get_config_value "${tmp_conf}" "baz")" "new config value not appended"

download_src_dir="$(mktemp -d)"
download_input="$(mktemp)"
printf 'download test\n' > "${download_input}"
LNMP_SRC_DIR="${download_src_dir}"
download_src "file://${download_input}" "downloaded.txt" "" >/dev/null
assert_eq "download test" "$(cat "${download_src_dir}/downloaded.txt")" "download without checksum should succeed"
if (download_src "file://${download_input}" "bad-checksum.txt" "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1); then
  fail "download with bad checksum should fail"
fi
[[ ! -e "${download_src_dir}/bad-checksum.txt.part" ]] || fail "failed download should remove partial file"
[[ ! -e "${download_src_dir}/bad-checksum.txt" ]] || fail "failed download should not publish cached file"
rm -rf "${download_src_dir}" "${download_input}"

echo "PASS: common helpers"
