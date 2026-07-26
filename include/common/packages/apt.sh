#!/usr/bin/env bash

# Debian/Ubuntu package manager support.

apt_lock_timeout() {
  local timeout="${LNMP_APT_LOCK_TIMEOUT:-600}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=600
  printf '%s' "${timeout}"
}

apt_lock_holder_pids() {
  local lock_path fd_path target pid
  local lock_paths="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
  if command_exists fuser; then
    for lock_path in ${lock_paths}; do
      [[ -e "${lock_path}" ]] || continue
      fuser "${lock_path}" 2>/dev/null || true
    done | tr ' ' '\n' | awk '/^[0-9]+$/ && !seen[$0]++'
    return 0
  fi

  [[ -d /proc ]] || return 0
  for fd_path in /proc/[0-9]*/fd/*; do
    [[ -e "${fd_path}" ]] || continue
    target="$(readlink "${fd_path}" 2>/dev/null || true)"
    case " ${lock_paths} " in *" ${target} "*) ;; *) continue ;; esac
    pid="${fd_path#/proc/}"
    pid="${pid%%/*}"
    printf '%s\n' "${pid}"
  done | awk '/^[0-9]+$/ && !seen[$0]++'
}

wait_for_apt_locks() {
  local timeout interval started elapsed holders pid last_notice
  timeout="$(apt_lock_timeout)"
  interval="${LNMP_APT_LOCK_POLL_INTERVAL:-2}"
  [[ "${interval}" =~ ^[1-9][0-9]*$ ]] || interval=2
  started=${SECONDS}
  last_notice=-30

  while true; do
    holders="$(apt_lock_holder_pids | xargs 2>/dev/null || true)"
    [[ -n "${holders}" ]] || return 0
    elapsed=$((SECONDS - started))
    if ((elapsed >= timeout)); then
      warn "Timed out after ${timeout} seconds waiting for the APT/dpkg lock. Holding processes: ${holders}"
      for pid in ${holders}; do
        ps -p "${pid}" -o pid=,etime=,comm=,args= 2>/dev/null || true
      done
      die "APT/dpkg is in use by another process. Wait for it to finish and retry; do not delete lock files"
    fi
    if ((elapsed - last_notice >= 30)); then
      info "APT/dpkg is in use by process ${holders}; waiting for release (${elapsed}/${timeout} seconds)"
      last_notice=${elapsed}
    fi
    sleep "${interval}"
  done
}

run_apt_get() {
  local timeout
  timeout="$(apt_lock_timeout)"
  DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=${timeout}" "$@"
}

apt_has_package_lists() {
  compgen -G "${LNMP_APT_LISTS_DIR:-/var/lib/apt/lists}/*_Packages*" >/dev/null 2>&1
}

# `apt-get update` exits non-zero when any single source fails, including a
# third-party PPA that is merely unreachable. Aborting the whole installation
# for that is wrong when the distribution's own lists are present, so transient
# failures are retried and a partial refresh degrades to a warning.
refresh_apt_metadata() {
  local attempt
  for attempt in 1 2 3; do
    if run_apt_get update; then
      return 0
    fi
    if ((attempt < 3)); then
      warn "APT metadata refresh failed (attempt ${attempt}/3); retrying"
      sleep "$((attempt * 3))"
    fi
  done
  if apt_has_package_lists; then
    warn "Some APT sources could not be refreshed; continuing with the cached package lists."
    warn "If dependency preflight then reports missing packages, fix the failing source first."
    return 0
  fi
  die "Failed to refresh APT metadata and no cached package lists are available; check the distribution repository or archive configuration"
}

# Pick the first candidate the configured repositories can actually install.
# Falls back to the last candidate so dependency preflight reports a concrete
# package name instead of an empty string.
apt_first_available_package() {
  local candidates=("$@")
  local package
  ((${#candidates[@]} > 0)) || return 1
  for package in "${candidates[@]}"; do
    if [[ -n "${LNMP_AVAILABLE_PACKAGES+x}" ]]; then
      validate_choice "${package}" "${LNMP_AVAILABLE_PACKAGES}" || continue
    elif command_exists apt-cache; then
      apt-cache show "${package}" >/dev/null 2>&1 || continue
    else
      continue
    fi
    printf '%s' "${package}"
    return 0
  done
  printf '%s' "${candidates[${#candidates[@]} - 1]}"
}

apt_libaio_package() {
  local version="${OS_VERSION_ID:-0}"
  case "${OS_ID:-}" in
    ubuntu)
      if [[ "${version}" =~ ^[0-9]+$ ]] && ((version >= 24)); then
        printf 'libaio1t64'
      else
        printf 'libaio1'
      fi
      ;;
    debian)
      if [[ "${version}" =~ ^[0-9]+$ ]] && ((version >= 13)); then
        printf 'libaio1t64'
      else
        printf 'libaio1'
      fi
      ;;
    *) apt_first_available_package libaio1t64 libaio1 ;;
  esac
}

apt_pcre_dev_package() {
  local version="${OS_VERSION_ID:-0}"
  if [[ "${OS_ID:-}" == "ubuntu" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 26)); then
    printf 'libpcre2-dev'
  elif [[ "${OS_ID:-}" == "debian" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 13)); then
    printf 'libpcre2-dev'
  elif [[ "${OS_ID:-}" == "ubuntu" || "${OS_ID:-}" == "debian" ]]; then
    printf 'libpcre3-dev'
  else
    apt_first_available_package libpcre3-dev libpcre2-dev
  fi
}

apt_freetype_dev_package() {
  local version="${OS_VERSION_ID:-0}"
  if [[ "${OS_ID:-}" == "ubuntu" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 26)); then
    printf 'libfreetype-dev'
  elif [[ "${OS_ID:-}" == "debian" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 13)); then
    printf 'libfreetype-dev'
  elif [[ "${OS_ID:-}" == "ubuntu" || "${OS_ID:-}" == "debian" ]]; then
    printf 'libfreetype6-dev'
  else
    apt_first_available_package libfreetype6-dev libfreetype-dev
  fi
}

libaio_compat_source() {
  local path
  for path in \
    "${LIBAIO_COMPAT_SOURCE_OVERRIDE:-}" \
    /lib/*/libaio.so.1t64 \
    /usr/lib/*/libaio.so.1t64 \
    /lib64/libaio.so.1t64 \
    /usr/lib64/libaio.so.1t64; do
    [[ -n "${path}" && -e "${path}" ]] || continue
    printf '%s' "${path}"
    return 0
  done
  return 1
}

ensure_libaio_compat() {
  if [[ -z "${LIBAIO_COMPAT_SOURCE_OVERRIDE:-}" && -z "${LIBAIO_COMPAT_TARGET_OVERRIDE:-}" ]] && \
     command_exists ldconfig && ldconfig -p 2>/dev/null | grep -q 'libaio\.so\.1 '; then
    return 0
  fi

  local source target
  source="$(libaio_compat_source 2>/dev/null)" || return 0
  target="${LIBAIO_COMPAT_TARGET_OVERRIDE:-$(dirname "${source}")/libaio.so.1}"
  if [[ ! -e "${target}" ]]; then
    ln -s "$(basename "${source}")" "${target}"
  fi
  command_exists ldconfig && ldconfig 2>/dev/null || true
}

apt_build_dependency_packages() {
  {
    printf '%s\n' wget curl ca-certificates tar xz-utils gzip bzip2
    if dependency_has_component nginx || dependency_has_component php || dependency_has_component redis; then
      printf '%s\n' build-essential gcc g++ make cmake autoconf pkg-config
    fi
    dependency_has_component nginx && printf '%s\n' libssl-dev zlib1g-dev "$(apt_pcre_dev_package)"
    if dependency_has_component php; then
      printf '%s\n' libssl-dev zlib1g-dev libxml2-dev libsqlite3-dev libcurl4-openssl-dev
      dependency_has_php_extension mbstring && printf '%s\n' libonig-dev
      dependency_has_php_extension gd && printf '%s\n' libjpeg-dev libpng-dev libwebp-dev "$(apt_freetype_dev_package)"
      dependency_has_php_extension zip && printf '%s\n' libzip-dev
      dependency_has_php_extension intl && printf '%s\n' libicu-dev
      dependency_has_php_extension bz2 && printf '%s\n' libbz2-dev
      dependency_has_php_extension sodium && printf '%s\n' libsodium-dev
      dependency_has_php_extension readline && printf '%s\n' libreadline-dev libncurses-dev
      dependency_has_php_extension ldap && printf '%s\n' libldap2-dev
      if dependency_has_php_extension imap && php_imap_build_supported_for_system; then
        printf '%s\n' libc-client2007e-dev libkrb5-dev
      fi
      dependency_has_php_extension xsl && printf '%s\n' libxslt1-dev
      dependency_has_php_extension gmp && printf '%s\n' libgmp-dev
      dependency_has_php_extension tidy && printf '%s\n' libtidy-dev
      dependency_has_php_extension snmp && printf '%s\n' libsnmp-dev
      if dependency_has_php_extension pgsql || dependency_has_php_extension pdo_pgsql; then printf '%s\n' libpq-dev; fi
      dependency_has_pecl_extension memcached && printf '%s\n' libmemcached-dev
      dependency_has_pecl_extension imagick && printf '%s\n' libmagickwand-dev
      dependency_has_pecl_extension yaml && printf '%s\n' libyaml-dev
      dependency_has_pecl_extension ssh2 && printf '%s\n' libssh2-1-dev
      dependency_has_pecl_extension rdkafka && printf '%s\n' librdkafka-dev
      dependency_has_pecl_extension uuid && printf '%s\n' uuid-dev
      dependency_has_pecl_extension amqp && printf '%s\n' librabbitmq-dev
      dependency_has_pecl_extension event && printf '%s\n' libevent-dev
    fi
    case "${db_engine:-none}" in mysql|mariadb) printf '%s\n' "$(apt_libaio_package)" numactl ;; esac
    dependency_has_component memcached && printf '%s\n' memcached
    :
  } | emit_unique_packages
}
