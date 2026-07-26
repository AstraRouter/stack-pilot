#!/usr/bin/env bash

# openSUSE Leap / Tumbleweed and SLES package manager support.
#
# SUSE keeps upstream sources identical to the Enterprise Linux builds but uses
# its own -devel package names (libopenssl-devel rather than openssl-devel,
# sqlite3-devel rather than sqlite-devel, and so on). Where a name changed
# between Leap 15 and Leap 16/Tumbleweed the candidates are listed newest-first
# and resolved against the configured repositories.

zypper_lock_timeout() {
  local timeout="${LNMP_ZYPPER_LOCK_TIMEOUT:-600}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=600
  printf '%s' "${timeout}"
}

# zypper serialises itself on the libzypp lock; ZYPP_LOCK_TIMEOUT makes it wait
# for a concurrent transaction instead of failing immediately.
run_zypper() {
  local timeout
  timeout="$(zypper_lock_timeout)"
  ZYPP_LOCK_TIMEOUT="${timeout}" zypper --non-interactive "$@"
}

zypper_package_exists() {
  local package="$1"
  if [[ -n "${LNMP_AVAILABLE_PACKAGES+x}" ]]; then
    validate_choice "${package}" "${LNMP_AVAILABLE_PACKAGES}"
    return $?
  fi
  rpm -q "${package}" >/dev/null 2>&1 && return 0
  command_exists zypper || return 1
  run_zypper --quiet search --match-exact --type package -- "${package}" >/dev/null 2>&1
}

# Resolve the first installable candidate, falling back to the last one so
# dependency preflight reports a concrete name instead of an empty string.
zypper_first_available_package() {
  local candidates=("$@")
  local package
  ((${#candidates[@]} > 0)) || return 1
  for package in "${candidates[@]}"; do
    zypper_package_exists "${package}" || continue
    printf '%s' "${package}"
    return 0
  done
  printf '%s' "${candidates[${#candidates[@]} - 1]}"
}

zypper_pkgconfig_package() { zypper_first_available_package pkg-config pkgconf-pkg-config; }
zypper_libaio_package() { zypper_first_available_package libaio1 libaio; }
zypper_numa_package() { zypper_first_available_package libnuma1 numactl; }
zypper_jpeg_dev_package() { zypper_first_available_package libjpeg8-devel libjpeg62-devel; }
zypper_png_dev_package() { zypper_first_available_package libpng16-devel libpng-devel; }
zypper_ssl_dev_package() { zypper_first_available_package libopenssl-devel openssl-devel; }

zypper_build_dependency_packages() {
  {
    printf '%s\n' wget curl ca-certificates tar xz gzip bzip2
    if dependency_has_component nginx || dependency_has_component php || dependency_has_component redis; then
      printf '%s\n' gcc gcc-c++ make cmake autoconf "$(zypper_pkgconfig_package)"
    fi
    dependency_has_component nginx && printf '%s\n' "$(zypper_ssl_dev_package)" zlib-devel pcre2-devel
    if dependency_has_component php; then
      printf '%s\n' "$(zypper_ssl_dev_package)" zlib-devel libxml2-devel sqlite3-devel libcurl-devel
      dependency_has_php_extension mbstring && printf '%s\n' oniguruma-devel
      dependency_has_php_extension gd && printf '%s\n' "$(zypper_jpeg_dev_package)" "$(zypper_png_dev_package)" libwebp-devel freetype2-devel
      dependency_has_php_extension zip && printf '%s\n' libzip-devel
      dependency_has_php_extension intl && printf '%s\n' libicu-devel
      dependency_has_php_extension bz2 && printf '%s\n' libbz2-devel
      dependency_has_php_extension sodium && printf '%s\n' libsodium-devel
      dependency_has_php_extension readline && printf '%s\n' readline-devel ncurses-devel
      dependency_has_php_extension ldap && printf '%s\n' openldap2-devel
      dependency_has_php_extension xsl && printf '%s\n' libxslt-devel
      dependency_has_php_extension gmp && printf '%s\n' gmp-devel
      dependency_has_php_extension tidy && printf '%s\n' libtidy-devel
      dependency_has_php_extension snmp && printf '%s\n' net-snmp-devel
      if dependency_has_php_extension pgsql || dependency_has_php_extension pdo_pgsql; then printf '%s\n' postgresql-devel; fi
      dependency_has_pecl_extension memcached && printf '%s\n' libmemcached-devel
      dependency_has_pecl_extension imagick && printf '%s\n' ImageMagick-devel
      dependency_has_pecl_extension yaml && printf '%s\n' libyaml-devel
      dependency_has_pecl_extension ssh2 && printf '%s\n' libssh2-devel
      dependency_has_pecl_extension rdkafka && printf '%s\n' librdkafka-devel
      dependency_has_pecl_extension uuid && printf '%s\n' libuuid-devel
      dependency_has_pecl_extension amqp && printf '%s\n' librabbitmq-devel
      dependency_has_pecl_extension event && printf '%s\n' libevent-devel
    fi
    case "${db_engine:-none}" in mysql|mariadb) printf '%s\n' "$(zypper_libaio_package)" "$(zypper_numa_package)" ;; esac
    dependency_has_component memcached && printf '%s\n' memcached
    :
  } | emit_unique_packages
}
