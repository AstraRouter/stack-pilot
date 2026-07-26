#!/usr/bin/env bash

# RPM package manager support (yum/dnf) for CentOS Stream, Rocky Linux,
# AlmaLinux, RHEL, Oracle Linux, and Amazon Linux 2023.

# Enterprise Linux generation whose package names a release follows. Amazon
# Linux 2023 reports VERSION_ID=2023 but names packages like EL9, so the raw
# version number must not be compared against EL majors directly.
rpm_el_generation() {
  local version="${OS_VERSION_ID:-0}"
  case "${OS_ID:-}" in
    centos|rocky|almalinux|rhel|ol) printf '%s' "${version}"; return 0 ;;
    amzn) printf '9'; return 0 ;;
  esac
  # Reached through ID_LIKE: only trust a plausible EL major.
  if [[ "${version}" =~ ^[0-9]+$ ]] && ((version >= 7 && version <= 10)); then
    printf '%s' "${version}"
  else
    printf '%s' "${LNMP_RPM_EL_GENERATION_DEFAULT:-9}"
  fi
}

# Repositories that ship the -devel headers excluded from the base channels.
# More than one name is listed where distributions renamed the repository
# between point releases; the first one actually present wins.
rpm_devel_repository_candidates() {
  local version="${OS_VERSION_ID:-0}"
  local arch="${ARCH:-x86_64}"
  case "${OS_ID:-}" in
    centos|rocky|almalinux)
      case "${version}" in
        8) printf '%s\n' powertools PowerTools ;;
        9|10) printf '%s\n' crb CRB ;;
      esac
      ;;
    rhel)
      case "${version}" in
        8|9|10) printf 'codeready-builder-for-rhel-%s-%s-rpms\n' "${version}" "${arch}" ;;
      esac
      ;;
    ol)
      case "${version}" in
        8|9|10) printf 'ol%s_codeready_builder\n' "${version}" ;;
      esac
      ;;
    # Amazon Linux 2023 ships development headers in its base repositories.
    amzn) ;;
  esac
}

rpm_devel_repository() {
  rpm_devel_repository_candidates | head -n 1
}

# EPEL provides oniguruma, ImageMagick, and several PECL build dependencies on
# Enterprise Linux. RHEL does not carry the release package itself, and Amazon
# Linux 2023 has no EPEL at all.
rpm_epel_release_candidates() {
  local version="${OS_VERSION_ID:-0}"
  case "${OS_ID:-}" in
    centos|rocky|almalinux) printf 'epel-release\n' ;;
    ol) printf 'oracle-epel-release-el%s\n' "${version}" ;;
    rhel)
      printf 'epel-release\n'
      printf 'https://dl.fedoraproject.org/pub/epel/epel-release-latest-%s.noarch.rpm\n' "${version}"
      ;;
    amzn) ;;
  esac
}

rpm_lock_holder_pid() {
  local lock_file pid
  for lock_file in ${LNMP_RPM_LOCK_FILES:-/run/dnf.pid /var/run/dnf.pid /run/yum.pid /var/run/yum.pid}; do
    [[ -r "${lock_file}" ]] || continue
    pid="$(head -n1 "${lock_file}" 2>/dev/null || true)"
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    # A stale pid file from a killed transaction must not block forever.
    kill -0 "${pid}" 2>/dev/null || continue
    printf '%s' "${pid}"
    return 0
  done
  return 1
}

# dnf and yum take an exclusive lock and fail immediately when a concurrent
# unattended update holds it, so wait the same way the APT path does.
wait_for_rpm_locks() {
  local timeout interval started elapsed holder last_notice
  timeout="${LNMP_RPM_LOCK_TIMEOUT:-600}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=600
  interval="${LNMP_RPM_LOCK_POLL_INTERVAL:-5}"
  [[ "${interval}" =~ ^[1-9][0-9]*$ ]] || interval=5
  started=${SECONDS}
  last_notice=-30

  while true; do
    holder="$(rpm_lock_holder_pid)" || return 0
    elapsed=$((SECONDS - started))
    if ((elapsed >= timeout)); then
      warn "Timed out after ${timeout} seconds waiting for the ${PM:-rpm} lock held by process ${holder}"
      die "${PM:-dnf} is in use by another process. Wait for it to finish and retry; do not delete lock files"
    fi
    if ((elapsed - last_notice >= 30)); then
      info "${PM:-dnf} is in use by process ${holder}; waiting for release (${elapsed}/${timeout} seconds)"
      last_notice=${elapsed}
    fi
    sleep "${interval}"
  done
}

rpm_config_manager_available() {
  case "${PM:-}" in
    dnf) dnf config-manager --help >/dev/null 2>&1 ;;
    yum) command_exists yum-config-manager ;;
    *) return 1 ;;
  esac
}

rpm_enable_repository() {
  local repository="$1"
  case "${PM:-}" in
    dnf) dnf config-manager --set-enabled "${repository}" ;;
    yum) yum-config-manager --enable "${repository}" >/dev/null ;;
    *) return 1 ;;
  esac
}

rpm_repository_disabled() {
  local repository="$1"
  LC_ALL=C "${PM}" repolist --all 2>/dev/null |
    awk -v repo="${repository}" '$1 == repo && $NF == "disabled" {found=1} END {exit !found}'
}

rpm_epel_installed() {
  rpm -q epel-release >/dev/null 2>&1 && return 0
  rpm -q "oracle-epel-release-el${OS_VERSION_ID:-0}" >/dev/null 2>&1
}

rpm_install_epel_release() {
  local candidate
  for candidate in $(rpm_epel_release_candidates); do
    case "${candidate}" in
      https://*)
        info "Installing the EPEL repository configuration from ${candidate}"
        "${PM}" install -y "${candidate}" && return 0
        ;;
      *)
        "${PM}" -q list --available "${candidate}" >/dev/null 2>&1 || continue
        "${PM}" install -y "${candidate}" && return 0
        ;;
    esac
  done
  return 1
}

rpm_enable_devel_repository() {
  local candidate config_manager_package
  local candidates
  candidates="$(rpm_devel_repository_candidates | xargs 2>/dev/null || true)"
  [[ -n "${candidates}" ]] || return 0

  if ! rpm_config_manager_available; then
    if [[ "${PM}" == "yum" ]]; then config_manager_package="yum-utils"; else config_manager_package="dnf-plugins-core"; fi
    "${PM}" install -y "${config_manager_package}"
  fi

  for candidate in ${candidates}; do
    rpm_repository_disabled "${candidate}" || continue
    if rpm_enable_repository "${candidate}"; then
      info "Enabled the ${candidate} repository for development headers"
      return 0
    fi
    warn "Could not enable the ${candidate} repository"
    if [[ "${OS_ID:-}" == "rhel" ]]; then
      warn "On RHEL this repository requires an active subscription: subscription-manager repos --enable ${candidate}"
    fi
  done
  return 0
}

prepare_package_repositories() {
  [[ "${LNMP_PACKAGE_REPOSITORIES_PREPARED:-}" == "1" ]] && return 0
  case "${PM:-}" in yum|dnf) ;; *) return 0 ;; esac

  rpm_enable_devel_repository

  if dependency_has_component php && ! rpm_epel_installed; then
    if rpm_install_epel_release; then
      info "Installed the EPEL repository configuration for PHP extension dependencies"
    elif [[ "${OS_ID:-}" == "amzn" ]]; then
      warn "Amazon Linux 2023 does not provide EPEL; PHP extensions needing EPEL-only headers are unavailable"
    else
      warn "epel-release is unavailable in the configured repositories; some PHP extensions may be unavailable"
    fi
  fi

  if [[ "${OS_ID:-}" == "centos" && "${OS_VERSION_ID:-0}" =~ ^[0-9]+$ ]] && ((OS_VERSION_ID <= 8)); then
    warn "CentOS ${OS_VERSION_ID} is EOL. Compatibility installation requires vault.centos.org; migrate as soon as possible"
  fi
  LNMP_PACKAGE_REPOSITORIES_PREPARED=1
  # Newly enabled repositories invalidate any metadata cached before this point.
  # shellcheck disable=SC2034
  LNMP_PACKAGE_METADATA_REFRESHED=0
}

rpm_pkgconfig_package() {
  local generation
  generation="$(rpm_el_generation)"
  ((generation >= 8)) && printf 'pkgconf-pkg-config' || printf 'pkgconfig'
}

rpm_zlib_dev_package() {
  local generation
  generation="$(rpm_el_generation)"
  ((generation >= 10)) && printf 'zlib-ng-compat-devel' || printf 'zlib-devel'
}

rpm_pcre_dev_package() {
  local generation
  generation="$(rpm_el_generation)"
  ((generation >= 8)) && printf 'pcre2-devel' || printf 'pcre-devel'
}

rpm_jpeg_dev_package() {
  printf 'libjpeg-turbo-devel'
}

rpm_libmemcached_dev_package() {
  local generation
  generation="$(rpm_el_generation)"
  ((generation >= 10)) && printf 'libmemcached-awesome-devel' || printf 'libmemcached-devel'
}

rpm_build_dependency_packages() {
  {
    printf '%s\n' wget curl ca-certificates tar xz gzip bzip2
    if dependency_has_component nginx || dependency_has_component php || dependency_has_component redis; then
      printf '%s\n' gcc gcc-c++ make cmake autoconf "$(rpm_pkgconfig_package)"
    fi
    dependency_has_component nginx && printf '%s\n' openssl-devel "$(rpm_zlib_dev_package)" "$(rpm_pcre_dev_package)"
    if dependency_has_component php; then
      printf '%s\n' openssl-devel "$(rpm_zlib_dev_package)" libxml2-devel sqlite-devel libcurl-devel
      dependency_has_php_extension mbstring && printf '%s\n' oniguruma-devel
      dependency_has_php_extension gd && printf '%s\n' "$(rpm_jpeg_dev_package)" libpng-devel libwebp-devel freetype-devel
      dependency_has_php_extension zip && printf '%s\n' libzip-devel
      dependency_has_php_extension intl && printf '%s\n' libicu-devel
      dependency_has_php_extension bz2 && printf '%s\n' bzip2-devel
      dependency_has_php_extension sodium && printf '%s\n' libsodium-devel
      dependency_has_php_extension readline && printf '%s\n' readline-devel ncurses-devel
      dependency_has_php_extension ldap && printf '%s\n' openldap-devel
      dependency_has_php_extension xsl && printf '%s\n' libxslt-devel
      dependency_has_php_extension gmp && printf '%s\n' gmp-devel
      dependency_has_php_extension tidy && printf '%s\n' libtidy-devel
      dependency_has_php_extension snmp && printf '%s\n' net-snmp-devel
      if dependency_has_php_extension pgsql || dependency_has_php_extension pdo_pgsql; then printf '%s\n' libpq-devel; fi
      dependency_has_pecl_extension memcached && printf '%s\n' "$(rpm_libmemcached_dev_package)"
      dependency_has_pecl_extension imagick && printf '%s\n' ImageMagick-devel
      dependency_has_pecl_extension yaml && printf '%s\n' libyaml-devel
      dependency_has_pecl_extension ssh2 && printf '%s\n' libssh2-devel
      dependency_has_pecl_extension rdkafka && printf '%s\n' librdkafka-devel
      dependency_has_pecl_extension uuid && printf '%s\n' libuuid-devel
      dependency_has_pecl_extension amqp && printf '%s\n' librabbitmq-devel
      dependency_has_pecl_extension event && printf '%s\n' libevent-devel
    fi
    case "${db_engine:-none}" in mysql|mariadb) printf '%s\n' libaio numactl ;; esac
    dependency_has_component memcached && printf '%s\n' memcached
    :
  } | emit_unique_packages
}
