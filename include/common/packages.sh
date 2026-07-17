#!/usr/bin/env bash

detect_os() {
  [[ -f /etc/os-release ]] || die "Only Linux distributions with /etc/os-release are supported"
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="$(printf '%s' "${ID}" | tr '[:upper:]' '[:lower:]')"
  OS_VERSION_ID="${VERSION_ID%%.*}"
  ARCH="$(uname -m)"
  case "${OS_ID}" in
    ubuntu|debian) PM="apt-get" ;;
    centos|rhel|rocky|almalinux|fedora|ol|amzn)
      if command_exists dnf; then PM="dnf"; else PM="yum"; fi
      ;;
    *) die "Unsupported operating system: ${OS_ID}" ;;
  esac
  validate_supported_os_version
}

supported_os_version() {
  local os_id="${1:-${OS_ID:-}}"
  local os_version="${2:-${OS_VERSION_ID:-}}"
  [[ "${os_version}" =~ ^[0-9]+$ ]] || return 1
  case "${os_id}" in
    centos) ((os_version >= 7 && os_version <= 10)) ;;
    ubuntu) ((os_version >= 22 && os_version <= 26)) ;;
    debian) ((os_version >= 11 && os_version <= 13)) ;;
    *) return 0 ;;
  esac
}

validate_supported_os_version() {
  supported_os_version && return 0
  case "${OS_ID:-}" in
    centos) die "Only CentOS 7-10 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    ubuntu) die "Only Ubuntu 22-26 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    debian) die "Only Debian 11-13 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    *) die "Unable to identify the operating system version: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}" ;;
  esac
}

install_packages() {
  local packages=("$@")
  ((${#packages[@]} > 0)) || return 0
  case "${PM:-}" in
    apt-get)
      [[ "${LNMP_PACKAGE_METADATA_REFRESHED:-}" == "1" ]] || refresh_package_metadata
      wait_for_apt_locks
      run_apt_get install -y "${packages[@]}"
      ;;
    yum|dnf)
      "${PM}" install -y "${packages[@]}"
      ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
}

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

setup_install_logging() {
  [[ "${LNMP_LOGGING_READY:-}" == "1" ]] && return 0
  mkdir -p "$(dirname "${LNMP_LOG_FILE}")" "$(dirname "${LNMP_ERROR_LOG_FILE}")"
  touch "${LNMP_LOG_FILE}" "${LNMP_ERROR_LOG_FILE}"
  chmod 600 "${LNMP_LOG_FILE}" "${LNMP_ERROR_LOG_FILE}" 2>/dev/null || true
  exec > >(tee -a "${LNMP_LOG_FILE}") 2> >(tee -a "${LNMP_ERROR_LOG_FILE}" | tee -a "${LNMP_LOG_FILE}" >&2)
  LNMP_LOGGING_READY=1
  {
    echo
    echo "===== install session $(date '+%F %T') ====="
    echo "Full log: ${LNMP_LOG_FILE}"
    echo "Error log: ${LNMP_ERROR_LOG_FILE}"
  }
}

refresh_package_metadata() {
  case "${PM:-}" in
    apt-get)
      wait_for_apt_locks
      run_apt_get update || die "Failed to refresh APT metadata; check the distribution repository or archive configuration"
      ;;
    yum|dnf)
      "${PM}" makecache -y || die "Failed to refresh RPM metadata. CentOS 7/8 is EOL; verify the vault.centos.org archive configuration"
      ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
  LNMP_PACKAGE_METADATA_REFRESHED=1
}

rpm_devel_repository() {
  local version="${OS_VERSION_ID:-0}"
  case "${OS_ID:-}" in
    centos)
      case "${version}" in
        8) printf 'powertools' ;;
        9|10) printf 'crb' ;;
      esac
      ;;
    rocky|almalinux)
      case "${version}" in
        8) printf 'powertools' ;;
        9|10) printf 'crb' ;;
      esac
      ;;
  esac
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

prepare_package_repositories() {
  [[ "${LNMP_PACKAGE_REPOSITORIES_PREPARED:-}" == "1" ]] && return 0
  case "${PM:-}" in yum|dnf) ;; *) return 0 ;; esac
  case "${OS_ID:-}" in centos|rhel|rocky|almalinux) ;; *) return 0 ;; esac

  local devel_repository config_manager_package
  devel_repository="$(rpm_devel_repository)"
  if [[ -n "${devel_repository}" ]] && ! rpm_config_manager_available; then
    if [[ "${PM}" == "yum" ]]; then config_manager_package="yum-utils"; else config_manager_package="dnf-plugins-core"; fi
    "${PM}" install -y "${config_manager_package}"
  fi
  if [[ -n "${devel_repository}" ]] && rpm_repository_disabled "${devel_repository}"; then
    rpm_enable_repository "${devel_repository}"
    info "Enabled the ${devel_repository} repository for PHP development dependencies"
  fi
  if dependency_has_component php && ! rpm -q epel-release >/dev/null 2>&1; then
    if "${PM}" -q list --available epel-release >/dev/null 2>&1; then
      "${PM}" install -y epel-release
      info "Installed the EPEL repository configuration for PHP extension dependencies"
    else
      warn "epel-release is unavailable in the configured repositories; some PHP extensions may be unavailable"
    fi
  fi
  if [[ "${OS_ID:-}" == "centos" && "${OS_VERSION_ID:-0}" =~ ^[0-9]+$ ]] && ((OS_VERSION_ID <= 8)); then
    warn "CentOS ${OS_VERSION_ID} is EOL. Compatibility installation requires vault.centos.org; migrate as soon as possible"
  fi
  LNMP_PACKAGE_REPOSITORIES_PREPARED=1
  LNMP_PACKAGE_METADATA_REFRESHED=0
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
    *)
      if command_exists apt-cache && apt-cache show libaio1t64 >/dev/null 2>&1; then
        printf 'libaio1t64'
      else
        printf 'libaio1'
      fi
      ;;
  esac
}

apt_pcre_dev_package() {
  local version="${OS_VERSION_ID:-0}"
  if [[ "${OS_ID:-}" == "ubuntu" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 26)); then
    printf 'libpcre2-dev'
  elif [[ "${OS_ID:-}" == "debian" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 13)); then
    printf 'libpcre2-dev'
  else
    printf 'libpcre3-dev'
  fi
}

apt_freetype_dev_package() {
  local version="${OS_VERSION_ID:-0}"
  if [[ "${OS_ID:-}" == "ubuntu" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 26)); then
    printf 'libfreetype-dev'
  elif [[ "${OS_ID:-}" == "debian" && "${version}" =~ ^[0-9]+$ ]] && ((version >= 13)); then
    printf 'libfreetype-dev'
  else
    printf 'libfreetype6-dev'
  fi
}

rpm_pkgconfig_package() {
  [[ "${OS_VERSION_ID:-0}" =~ ^[0-9]+$ ]] && ((OS_VERSION_ID >= 8)) && printf 'pkgconf-pkg-config' || printf 'pkgconfig'
}

rpm_zlib_dev_package() {
  [[ "${OS_VERSION_ID:-0}" =~ ^[0-9]+$ ]] && ((OS_VERSION_ID >= 10)) && printf 'zlib-ng-compat-devel' || printf 'zlib-devel'
}

rpm_pcre_dev_package() {
  [[ "${OS_VERSION_ID:-0}" =~ ^[0-9]+$ ]] && ((OS_VERSION_ID >= 8)) && printf 'pcre2-devel' || printf 'pcre-devel'
}

rpm_jpeg_dev_package() {
  printf 'libjpeg-turbo-devel'
}

rpm_libmemcached_dev_package() {
  if [[ "${OS_VERSION_ID:-0}" =~ ^[0-9]+$ ]] && ((OS_VERSION_ID >= 10)); then
    printf 'libmemcached-awesome-devel'
  else
    printf 'libmemcached-devel'
  fi
}

php_imap_build_supported_for_system() {
  local version="${OS_VERSION_ID:-0}"
  [[ "${version}" =~ ^[0-9]+$ ]] || return 0
  case "${OS_ID:-}" in
    centos) ((version < 10)) ;;
    ubuntu) ((version < 26)) ;;
    debian) ((version < 13)) ;;
    *) return 0 ;;
  esac
}

dependency_has_component() {
  [[ " ${install_components:-nginx php mysql redis} " == *" $1 "* ]]
}

dependency_has_php_extension() {
  local selected="${php_extensions:-opcache mysqli pdo_mysql mbstring curl openssl gd zip fileinfo exif intl bcmath sockets pcntl bz2 sodium}"
  [[ " ${selected} " == *" $1 "* ]]
}

dependency_has_pecl_extension() {
  local selected="${php_pecl_extensions:-redis imagick}"
  [[ " ${selected} " == *" $1 "* ]]
}

emit_unique_packages() { awk 'NF && !seen[$0]++'; }

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

system_dependency_packages() {
  case "${PM:-}" in
    apt-get) apt_build_dependency_packages ;;
    yum|dnf) rpm_build_dependency_packages ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
}

package_available() {
  local package="$1"
  if [[ -n "${LNMP_AVAILABLE_PACKAGES+x}" ]]; then
    validate_choice "${package}" "${LNMP_AVAILABLE_PACKAGES}"
    return $?
  fi

  case "${PM:-}" in
    apt-get)
      local candidate
      candidate="$(apt-cache policy "${package}" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
      [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
      ;;
    yum|dnf)
      rpm -q "${package}" >/dev/null 2>&1 || "${PM}" -q list --available "${package}" >/dev/null 2>&1
      ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
}

missing_dependency_packages() {
  local package
  for package in "$@"; do
    [[ -n "${package}" ]] || continue
    package_available "${package}" || printf '%s\n' "${package}"
  done
}

dependency_package_reason() {
  case "$1" in
    *pcre*-devel|libpcre*-dev) printf 'Nginx rewrite and regular-expression support' ;;
    *freetype*-dev|freetype-devel|libjpeg*-dev|libjpeg*-devel|libpng*-dev|libpng-devel|libwebp*-dev|libwebp-devel) printf 'PHP gd image extension' ;;
    *oniguruma*|libonig-dev) printf 'PHP mbstring extension' ;;
    *libzip*|libzip-dev) printf 'PHP zip extension' ;;
    *icu*|libicu-dev) printf 'PHP intl extension' ;;
    *sodium*|libsodium-dev) printf 'PHP sodium extension' ;;
    *magick*|ImageMagick-devel) printf 'PHP imagick extension' ;;
    *memcached*) printf 'PHP memcached extension' ;;
    *rdkafka*) printf 'PHP rdkafka extension' ;;
    *yaml*) printf 'PHP yaml extension' ;;
    *ssh2*) printf 'PHP ssh2 extension' ;;
    libaio*|numactl) printf 'MySQL/MariaDB runtime library' ;;
    *) printf 'base build or runtime dependency' ;;
  esac
}

preflight_system_dependencies() {
  [[ "${LNMP_SKIP_DEPENDENCY_PREFLIGHT:-}" == "1" ]] && return 0
  [[ "${LNMP_DEPENDENCY_PREFLIGHT_DONE:-}" == "1" ]] && return 0

  local packages missing package
  detect_os
  prepare_package_repositories
  refresh_package_metadata
  mapfile -t packages < <(system_dependency_packages)
  mapfile -t missing < <(missing_dependency_packages "${packages[@]}")
  if ((${#missing[@]} > 0)); then
    warn "The configured repositories are missing these dependencies:"
    for package in "${missing[@]}"; do
      warn "  - ${package} ($(dependency_package_reason "${package}"))"
    done
    die "Dependency preflight failed; fix the repositories and retry"
  fi
  LNMP_DEPENDENCY_PREFLIGHT_DONE=1
  ok "Dependency preflight passed: ${#packages[@]} packages are available"
}

install_build_dependencies() {
  local packages
  detect_os
  prepare_package_repositories
  if [[ "${PM}" == "apt-get" ]]; then
    mapfile -t packages < <(apt_build_dependency_packages)
    install_packages "${packages[@]}"
    ensure_libaio_compat
  else
    mapfile -t packages < <(rpm_build_dependency_packages)
    install_packages "${packages[@]}"
  fi
}

ensure_user_group() {
  local user="$1"
  local group="$2"
  getent group "${group}" >/dev/null 2>&1 || groupadd -r "${group}"
  id "${user}" >/dev/null 2>&1 || useradd -r -g "${group}" -s /sbin/nologin -M "${user}"
}
