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

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "${haystack}" == *" ${needle} "* ]] || fail "${message}: '${needle}' missing"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "${haystack}" != *" ${needle} "* ]] || fail "${message}: '${needle}' should not be present"
}

write_os_release() {
  printf '%s\n' "$@" > "${os_release_file}"
}

# --- distribution family mapping ---------------------------------------------

for distro_id in ubuntu debian; do
  assert_eq "debian" "$(os_family_for_id "${distro_id}")" "${distro_id} should map to the debian family"
done
for distro_id in centos rocky almalinux rhel ol amzn; do
  assert_eq "rhel" "$(os_family_for_id "${distro_id}")" "${distro_id} should map to the rhel family"
done
for distro_id in opensuse-leap opensuse-tumbleweed sles; do
  assert_eq "suse" "$(os_family_for_id "${distro_id}")" "${distro_id} should map to the suse family"
done
if os_family_for_id arch >/dev/null 2>&1; then fail "unknown distribution id should not resolve a family"; fi

# --- ID_LIKE derivative fallback ---------------------------------------------

assert_eq "debian" "$(os_family_for_id_like "ubuntu debian")" "ID_LIKE ubuntu/debian should resolve the debian family"
assert_eq "rhel" "$(os_family_for_id_like "rhel fedora")" "ID_LIKE rhel/fedora should resolve the rhel family"
assert_eq "rhel" "$(os_family_for_id_like "centos rhel fedora")" "ID_LIKE centos should resolve the rhel family"
assert_eq "suse" "$(os_family_for_id_like "suse opensuse")" "ID_LIKE suse should resolve the suse family"
if os_family_for_id_like "" >/dev/null 2>&1; then fail "empty ID_LIKE should not resolve a family"; fi
if os_family_for_id_like "arch" >/dev/null 2>&1; then fail "unrelated ID_LIKE should not resolve a family"; fi

# --- package manager selection ------------------------------------------------

assert_eq "apt-get" "$(package_manager_for_family debian)" "debian family should use apt-get"
assert_eq "zypper" "$(package_manager_for_family suse)" "suse family should use zypper"
assert_eq "dnf" "$(command_exists() { [[ "$1" == "dnf" ]]; }; package_manager_for_family rhel)" \
  "rhel family should prefer dnf when available"
assert_eq "yum" "$(command_exists() { return 1; }; package_manager_for_family rhel)" \
  "rhel family should fall back to yum when dnf is absent"
if package_manager_for_family arch >/dev/null 2>&1; then fail "unknown family should not resolve a package manager"; fi

# --- supported version ranges -------------------------------------------------

for matrix_version in 8 9 10; do
  supported_os_version rhel "${matrix_version}" || fail "RHEL ${matrix_version} should be supported"
  supported_os_version ol "${matrix_version}" || fail "Oracle Linux ${matrix_version} should be supported"
  supported_os_version rocky "${matrix_version}" || fail "Rocky Linux ${matrix_version} should be supported"
  supported_os_version almalinux "${matrix_version}" || fail "AlmaLinux ${matrix_version} should be supported"
done
if supported_os_version rhel 7; then fail "RHEL 7 should be rejected"; fi
if supported_os_version rhel 11; then fail "RHEL 11 should be rejected"; fi
if supported_os_version ol 7; then fail "Oracle Linux 7 should be rejected"; fi

supported_os_version amzn 2023 || fail "Amazon Linux 2023 should be supported"
if supported_os_version amzn 2; then fail "Amazon Linux 2 is EL7-based and should be rejected"; fi

for matrix_version in 15 16; do
  supported_os_version opensuse-leap "${matrix_version}" || fail "openSUSE Leap ${matrix_version} should be supported"
  supported_os_version sles "${matrix_version}" || fail "SLES ${matrix_version} should be supported"
done
if supported_os_version opensuse-leap 14; then fail "openSUSE Leap 14 should be rejected"; fi
if supported_os_version sles 17; then fail "SLES 17 should be rejected"; fi
supported_os_version opensuse-tumbleweed 20260726 || fail "rolling Tumbleweed snapshots should be accepted"

# --- development repositories -------------------------------------------------

OS_ID=rhel
ARCH=x86_64
for matrix_version in 8 9 10; do
  OS_VERSION_ID="${matrix_version}"
  assert_eq "codeready-builder-for-rhel-${matrix_version}-x86_64-rpms" "$(rpm_devel_repository)" \
    "RHEL ${matrix_version} CodeReady Builder repository name incorrect"
done
OS_VERSION_ID=9
ARCH=aarch64
assert_eq "codeready-builder-for-rhel-9-aarch64-rpms" "$(rpm_devel_repository)" \
  "RHEL CodeReady Builder repository should follow the detected architecture"
ARCH=x86_64

OS_ID=ol
for matrix_version in 8 9 10; do
  OS_VERSION_ID="${matrix_version}"
  assert_eq "ol${matrix_version}_codeready_builder" "$(rpm_devel_repository)" \
    "Oracle Linux ${matrix_version} CodeReady Builder repository name incorrect"
done

OS_ID=amzn
OS_VERSION_ID=2023
assert_eq "" "$(rpm_devel_repository_candidates)" "Amazon Linux 2023 ships devel headers in its base repositories"

OS_ID=rocky
OS_VERSION_ID=8
assert_eq "powertools PowerTools" "$(rpm_devel_repository_candidates | xargs)" \
  "Rocky Linux 8 should try both PowerTools spellings"
OS_VERSION_ID=9
assert_eq "crb CRB" "$(rpm_devel_repository_candidates | xargs)" "Rocky Linux 9 should try both CRB spellings"
assert_eq "crb" "$(rpm_devel_repository)" "rpm_devel_repository should return the preferred candidate"

# --- EPEL release packages ----------------------------------------------------

OS_ID=centos
OS_VERSION_ID=9
assert_eq "epel-release" "$(rpm_epel_release_candidates)" "CentOS should install epel-release from its repositories"
OS_ID=almalinux
assert_eq "epel-release" "$(rpm_epel_release_candidates)" "AlmaLinux should install epel-release from its repositories"
OS_ID=ol
for matrix_version in 8 9; do
  OS_VERSION_ID="${matrix_version}"
  assert_eq "oracle-epel-release-el${matrix_version}" "$(rpm_epel_release_candidates)" \
    "Oracle Linux ${matrix_version} should use its own EPEL release package"
done
OS_ID=rhel
OS_VERSION_ID=9
rhel_epel_candidates="$(rpm_epel_release_candidates | xargs)"
assert_eq "epel-release https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm" \
  "${rhel_epel_candidates}" "RHEL should fall back to the published EPEL release RPM"
OS_ID=amzn
OS_VERSION_ID=2023
assert_eq "" "$(rpm_epel_release_candidates)" "Amazon Linux 2023 has no EPEL"

# --- Enterprise Linux generation mapping --------------------------------------

OS_ID=amzn
OS_VERSION_ID=2023
assert_eq "9" "$(rpm_el_generation)" "Amazon Linux 2023 should follow EL9 package naming"
OS_ID=centos
OS_VERSION_ID=9
assert_eq "9" "$(rpm_el_generation)" "CentOS 9 should map to EL9"
OS_ID=openeuler
OS_VERSION_ID=24
assert_eq "9" "$(rpm_el_generation)" "a derivative version that is not an EL major should use the default generation"
OS_ID=openeuler
OS_VERSION_ID=9
assert_eq "9" "$(rpm_el_generation)" "a derivative reporting a plausible EL major should keep it"

# Amazon Linux 2023 must not be treated as "newer than EL10" by the >= checks.
OS_ID=amzn
OS_VERSION_ID=2023
assert_eq "zlib-devel" "$(rpm_zlib_dev_package)" "Amazon Linux 2023 zlib mapping incorrect"
assert_eq "pcre2-devel" "$(rpm_pcre_dev_package)" "Amazon Linux 2023 PCRE mapping incorrect"
assert_eq "pkgconf-pkg-config" "$(rpm_pkgconfig_package)" "Amazon Linux 2023 pkg-config mapping incorrect"
assert_eq "libmemcached-devel" "$(rpm_libmemcached_dev_package)" "Amazon Linux 2023 libmemcached mapping incorrect"

OS_ID=rhel
OS_VERSION_ID=9
assert_eq "zlib-devel" "$(rpm_zlib_dev_package)" "RHEL 9 zlib mapping incorrect"
assert_eq "pcre2-devel" "$(rpm_pcre_dev_package)" "RHEL 9 PCRE mapping incorrect"
OS_VERSION_ID=10
assert_eq "zlib-ng-compat-devel" "$(rpm_zlib_dev_package)" "RHEL 10 zlib mapping incorrect"
OS_ID=ol
OS_VERSION_ID=8
assert_eq "zlib-devel" "$(rpm_zlib_dev_package)" "Oracle Linux 8 zlib mapping incorrect"
assert_eq "pkgconf-pkg-config" "$(rpm_pkgconfig_package)" "Oracle Linux 8 pkg-config mapping incorrect"

# --- IMAP build support -------------------------------------------------------

install_components="nginx php mysql redis"
db_engine=mysql
php_extensions="opcache mysqli pdo_mysql mbstring curl openssl gd zip fileinfo exif intl bcmath sockets pcntl bz2 sodium"
php_pecl_extensions="redis imagick"

OS_ID=rhel
OS_VERSION_ID=9
php_imap_build_supported_for_system || fail "RHEL 9 should still provide the legacy IMAP build dependency"
OS_VERSION_ID=10
if php_imap_build_supported_for_system; then fail "RHEL 10 should skip the unavailable legacy IMAP build dependency"; fi
OS_ID=amzn
OS_VERSION_ID=2023
if php_imap_build_supported_for_system; then fail "Amazon Linux 2023 should skip the legacy IMAP build dependency"; fi
OS_ID=opensuse-leap
OS_VERSION_ID=15
if php_imap_build_supported_for_system; then fail "openSUSE should skip the legacy IMAP build dependency"; fi

# --- zypper dependency mapping ------------------------------------------------

PM=zypper
OS_ID=opensuse-leap
OS_VERSION_ID=15
php_extensions="opcache mysqli pdo_mysql mbstring curl openssl gd zip intl bz2 sodium ldap pgsql readline"
LNMP_AVAILABLE_PACKAGES="libopenssl-devel pkg-config libaio1 libnuma1 libjpeg8-devel libpng16-devel"
suse_deps=" $(zypper_build_dependency_packages | tr '\n' ' ') "
unset LNMP_AVAILABLE_PACKAGES

assert_contains "${suse_deps}" "libopenssl-devel" "openSUSE should use the SUSE OpenSSL development package"
assert_not_contains "${suse_deps}" "openssl-devel" "openSUSE should not use the Enterprise Linux OpenSSL package name"
assert_contains "${suse_deps}" "sqlite3-devel" "openSUSE should use sqlite3-devel"
assert_not_contains "${suse_deps}" "sqlite-devel" "openSUSE should not use the Enterprise Linux sqlite package name"
assert_contains "${suse_deps}" "freetype2-devel" "openSUSE should use freetype2-devel"
assert_contains "${suse_deps}" "openldap2-devel" "openSUSE should use openldap2-devel for PHP ldap"
assert_contains "${suse_deps}" "postgresql-devel" "openSUSE should use postgresql-devel for PHP pgsql"
assert_contains "${suse_deps}" "libbz2-devel" "openSUSE should use libbz2-devel for PHP bz2"
assert_contains "${suse_deps}" "pcre2-devel" "openSUSE should use pcre2-devel for Nginx"
assert_contains "${suse_deps}" "libjpeg8-devel" "openSUSE should resolve the available JPEG development package"
assert_contains "${suse_deps}" "libpng16-devel" "openSUSE should resolve the available PNG development package"
assert_contains "${suse_deps}" "libaio1" "openSUSE should resolve the MySQL/MariaDB aio runtime package"
assert_contains "${suse_deps}" "libnuma1" "openSUSE should resolve the MySQL/MariaDB NUMA runtime package"

# Unresolvable candidates must still emit a concrete name so preflight can
# report it rather than silently dropping the dependency.
LNMP_AVAILABLE_PACKAGES="nothing-matches"
assert_eq "libjpeg62-devel" "$(zypper_jpeg_dev_package)" "unresolved candidates should fall back to the last name"
unset LNMP_AVAILABLE_PACKAGES

PM=zypper
assert_eq "600" "$(zypper_lock_timeout)" "default zypper lock timeout incorrect"
LNMP_ZYPPER_LOCK_TIMEOUT=45
assert_eq "45" "$(zypper_lock_timeout)" "custom zypper lock timeout incorrect"
LNMP_ZYPPER_LOCK_TIMEOUT=invalid
assert_eq "600" "$(zypper_lock_timeout)" "invalid zypper lock timeout should use the default"
unset LNMP_ZYPPER_LOCK_TIMEOUT

suse_all_deps=" $(system_dependency_packages | tr '\n' ' ') "
assert_contains "${suse_all_deps}" "libxml2-devel" "system dependency dispatch should reach the zypper map"

# --- os-release parsing and detect_os ----------------------------------------

os_release_dir="$(mktemp -d)"
trap 'rm -rf "${os_release_dir}"' EXIT
os_release_file="${os_release_dir}/os-release"
LNMP_OS_RELEASE_FILE="${os_release_file}"

write_os_release 'ID="rocky"' 'VERSION_ID="9.4"' 'ID_LIKE="rhel centos fedora"'
assert_eq "rocky" "$(os_release_value ID)" "quoted os-release values should be unquoted"
assert_eq "9.4" "$(os_release_value VERSION_ID)" "os-release VERSION_ID should be read verbatim"
assert_eq "rhel centos fedora" "$(os_release_value ID_LIKE)" "os-release ID_LIKE should be read verbatim"
if os_release_value MISSING_KEY >/dev/null 2>&1; then fail "absent os-release keys should report failure"; fi

write_os_release 'ID=rocky' 'VERSION_ID=9.4'
assert_eq "rocky" "$(os_release_value ID)" "unquoted os-release values should be read"

# os-release must not be able to define or overwrite shell variables.
write_os_release 'ID=rocky' 'VERSION_ID=9' 'PM=hacked' 'LNMP_SRC_DIR=/tmp/evil'
guard_pm="${PM:-}"
os_release_value ID >/dev/null
assert_eq "${guard_pm}" "${PM:-}" "reading os-release must not overwrite existing shell variables"

detect_os_family() (
  write_os_release "$@"
  command_exists() { [[ "$1" == "dnf" ]]; }
  warn() { :; }
  detect_os
  printf '%s %s %s %s' "${OS_ID}" "${OS_VERSION_ID}" "${OS_FAMILY}" "${PM}"
)

assert_eq "rocky 9 rhel dnf" "$(detect_os_family 'ID=rocky' 'VERSION_ID="9.4"')" \
  "Rocky Linux detection incorrect"
assert_eq "rhel 9 rhel dnf" "$(detect_os_family 'ID="rhel"' 'VERSION_ID="9.4"')" \
  "RHEL detection incorrect"
assert_eq "ol 9 rhel dnf" "$(detect_os_family 'ID="ol"' 'VERSION_ID="9.3"')" \
  "Oracle Linux detection incorrect"
assert_eq "amzn 2023 rhel dnf" "$(detect_os_family 'ID="amzn"' 'VERSION_ID="2023"')" \
  "Amazon Linux 2023 detection incorrect"
assert_eq "opensuse-leap 15 suse zypper" "$(detect_os_family 'ID="opensuse-leap"' 'VERSION_ID="15.6"')" \
  "openSUSE Leap detection incorrect"
assert_eq "sles 15 suse zypper" "$(detect_os_family 'ID="sles"' 'VERSION_ID="15.6"')" \
  "SLES detection incorrect"
assert_eq "opensuse-tumbleweed 20260726 suse zypper" \
  "$(detect_os_family 'ID="opensuse-tumbleweed"' 'VERSION_ID="20260726"')" \
  "openSUSE Tumbleweed detection incorrect"
assert_eq "ubuntu 24 debian apt-get" "$(detect_os_family 'ID=ubuntu' 'VERSION_ID="24.04"')" \
  "Ubuntu detection incorrect"

# Derivatives are accepted through ID_LIKE rather than rejected outright.
assert_eq "openeuler 9 rhel dnf" \
  "$(detect_os_family 'ID="openeuler"' 'VERSION_ID="9"' 'ID_LIKE="rhel fedora"')" \
  "an unlisted RHEL derivative should be accepted through ID_LIKE"
assert_eq "linuxmint 22 debian apt-get" \
  "$(detect_os_family 'ID=linuxmint' 'VERSION_ID="22"' 'ID_LIKE="ubuntu debian"')" \
  "an unlisted Debian derivative should be accepted through ID_LIKE"

derivative_warning="$(
  write_os_release 'ID="openeuler"' 'VERSION_ID="9"' 'ID_LIKE="rhel fedora"'
  command_exists() { [[ "$1" == "dnf" ]]; }
  detect_os 2>&1 >/dev/null
)"
[[ "${derivative_warning}" == *"openeuler"* && "${derivative_warning}" == *"ID_LIKE"* ]] ||
  fail "an ID_LIKE fallback should warn that the distribution is untested"

detect_os_fails() (
  write_os_release "$@"
  command_exists() { [[ "$1" == "dnf" ]]; }
  warn() { :; }
  detect_os >/dev/null 2>&1
)

if detect_os_fails 'ID=arch' 'VERSION_ID="rolling"'; then
  fail "an unrelated distribution should be rejected"
fi
if detect_os_fails 'VERSION_ID="9"'; then
  fail "os-release without ID should be rejected"
fi
if detect_os_fails 'ID=rhel' 'VERSION_ID="7"'; then
  fail "RHEL 7 should be rejected by the version range"
fi
if detect_os_fails 'ID=amzn' 'VERSION_ID="2"'; then
  fail "Amazon Linux 2 should be rejected by the version range"
fi

echo "PASS: distribution support matrix"
