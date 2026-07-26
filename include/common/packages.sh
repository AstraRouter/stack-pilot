#!/usr/bin/env bash

# Package manager orchestration.
#
# Distribution detection and the per-package-manager implementations live in
# include/common/packages/. Everything in this file dispatches on PM (set by
# detect_os) and stays package-manager agnostic.

_PACKAGES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packages"
for _packages_module in detect apt rpm zypper; do
  # shellcheck source=/dev/null
  source "${_PACKAGES_MODULE_DIR}/${_packages_module}.sh"
done
unset _PACKAGES_MODULE_DIR _packages_module

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
      wait_for_rpm_locks
      "${PM}" install -y "${packages[@]}"
      ;;
    zypper)
      [[ "${LNMP_PACKAGE_METADATA_REFRESHED:-}" == "1" ]] || refresh_package_metadata
      run_zypper install --no-recommends -- "${packages[@]}"
      ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
}

refresh_package_metadata() {
  case "${PM:-}" in
    apt-get)
      wait_for_apt_locks
      refresh_apt_metadata
      ;;
    yum|dnf)
      wait_for_rpm_locks
      "${PM}" makecache -y || die "Failed to refresh RPM metadata. CentOS 7/8 is EOL; verify the vault.centos.org archive configuration"
      ;;
    zypper)
      run_zypper refresh || die "Failed to refresh zypper metadata; check the configured repositories"
      ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
  LNMP_PACKAGE_METADATA_REFRESHED=1
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
    zypper)
      zypper_package_exists "${package}"
      ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
}

system_dependency_packages() {
  case "${PM:-}" in
    apt-get) apt_build_dependency_packages ;;
    yum|dnf) rpm_build_dependency_packages ;;
    zypper) zypper_build_dependency_packages ;;
    *) die "Unknown package manager: ${PM:-unset}" ;;
  esac
}

install_build_dependencies() {
  local packages
  detect_os
  prepare_package_repositories
  mapfile -t packages < <(system_dependency_packages)
  ((${#packages[@]} > 0)) || return 0
  install_packages "${packages[@]}"
  [[ "${PM}" == "apt-get" ]] && ensure_libaio_compat
  return 0
}

emit_unique_packages() { awk 'NF && !seen[$0]++'; }

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

# PHP unbundled IMAP in 8.4 and several distributions dropped the legacy
# c-client build dependency; skipping is safer than failing the whole build.
php_imap_build_supported_for_system() {
  local version="${OS_VERSION_ID:-0}"
  case "${OS_ID:-}" in
    amzn|opensuse-leap|opensuse-tumbleweed|sles) return 1 ;;
  esac
  [[ "${version}" =~ ^[0-9]+$ ]] || return 0
  case "${OS_ID:-}" in
    centos|rocky|almalinux|rhel|ol) ((version < 10)) ;;
    ubuntu) ((version < 26)) ;;
    debian) ((version < 13)) ;;
    *) return 0 ;;
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
    *freetype*-dev|freetype-devel|freetype2-devel|libjpeg*-dev|libjpeg*-devel|libpng*-dev|libpng*-devel|libwebp*-dev|libwebp-devel) printf 'PHP gd image extension' ;;
    *oniguruma*|libonig-dev) printf 'PHP mbstring extension' ;;
    *libzip*) printf 'PHP zip extension' ;;
    *icu*) printf 'PHP intl extension' ;;
    *sodium*) printf 'PHP sodium extension' ;;
    *magick*|ImageMagick-devel) printf 'PHP imagick extension' ;;
    *memcached*) printf 'PHP memcached extension' ;;
    *rdkafka*) printf 'PHP rdkafka extension' ;;
    *yaml*) printf 'PHP yaml extension' ;;
    *ssh2*) printf 'PHP ssh2 extension' ;;
    openldap2-devel|libldap*-dev|openldap-devel) printf 'PHP ldap extension' ;;
    postgresql-devel|libpq-dev*) printf 'PHP pgsql extension' ;;
    libaio*|numactl|libnuma*) printf 'MySQL/MariaDB runtime library' ;;
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
    warn "Detected system: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown} (${OS_FAMILY:-unknown} family, ${PM:-unset})"
    die "Dependency preflight failed; fix the repositories and retry"
  fi
  LNMP_DEPENDENCY_PREFLIGHT_DONE=1
  ok "Dependency preflight passed: ${#packages[@]} packages are available"
}

setup_install_logging() {
  [[ "${LNMP_LOGGING_READY:-}" == "1" ]] && return 0
  mkdir -p "$(dirname "${LNMP_LOG_FILE}")" "$(dirname "${LNMP_ERROR_LOG_FILE}")"
  touch "${LNMP_LOG_FILE}" "${LNMP_ERROR_LOG_FILE}"
  chmod 600 "${LNMP_LOG_FILE}" "${LNMP_ERROR_LOG_FILE}" 2>/dev/null || true
  # Colours were chosen while stdout was still a terminal, so the escape
  # sequences must be stripped on the way to the log files; otherwise every
  # logged line carries raw ANSI codes.
  exec > >(tee >(strip_ansi_escapes >> "${LNMP_LOG_FILE}")) \
      2> >(tee >(strip_ansi_escapes >> "${LNMP_ERROR_LOG_FILE}") \
           >(strip_ansi_escapes >> "${LNMP_LOG_FILE}") >&2)
  LNMP_LOGGING_READY=1
  {
    echo
    echo "===== install session $(date '+%F %T') ====="
    echo "Full log: ${LNMP_LOG_FILE}"
    echo "Error log: ${LNMP_ERROR_LOG_FILE}"
  }
}

ensure_user_group() {
  local user="$1"
  local group="$2"
  getent group "${group}" >/dev/null 2>&1 || groupadd -r "${group}"
  id "${user}" >/dev/null 2>&1 || useradd -r -g "${group}" -s /sbin/nologin -M "${user}"
}
