#!/usr/bin/env bash

# Operating-system detection and the distribution support matrix.
#
# Distributions are grouped into families that share a package manager and a
# package-naming scheme. Everything downstream keys off OS_FAMILY and PM rather
# than off individual distribution IDs, so a derivative that reports a known
# ID_LIKE works without a dedicated branch.

LNMP_OS_RELEASE_FILE="${LNMP_OS_RELEASE_FILE:-/etc/os-release}"

# Read a single key from os-release without sourcing it, so the file cannot
# execute code or overwrite unrelated shell variables.
os_release_value() {
  local key="$1"
  local file="${2:-${LNMP_OS_RELEASE_FILE}}"
  local line value
  [[ -f "${file}" ]] || return 1
  line="$(grep -m1 -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null || true)"
  [[ -n "${line}" ]] || return 1
  value="${line#*=}"
  value="${value%$'\r'}"
  value="${value#[\"\']}"
  value="${value%[\"\']}"
  printf '%s' "${value}"
}

# Distributions verified against the package maps in this repository.
os_family_for_id() {
  case "$1" in
    ubuntu|debian) printf 'debian' ;;
    centos|rocky|almalinux|rhel|ol|amzn) printf 'rhel' ;;
    opensuse-leap|opensuse-tumbleweed|sles) printf 'suse' ;;
    *) return 1 ;;
  esac
}

# Fallback for rebuilds and derivatives that keep upstream package names but
# report their own ID (openEuler, Anolis, Kylin, Linux Mint, Raspbian, ...).
os_family_for_id_like() {
  local token
  for token in ${1:-}; do
    case "${token}" in
      debian|ubuntu) printf 'debian'; return 0 ;;
      rhel|fedora|centos) printf 'rhel'; return 0 ;;
      suse|opensuse|sles) printf 'suse'; return 0 ;;
    esac
  done
  return 1
}

package_manager_for_family() {
  case "$1" in
    debian) printf 'apt-get' ;;
    rhel) if command_exists dnf; then printf 'dnf'; else printf 'yum'; fi ;;
    suse) printf 'zypper' ;;
    *) return 1 ;;
  esac
}

supported_os_id() {
  os_family_for_id "${1:-${OS_ID:-}}" >/dev/null 2>&1
}

supported_os_version() {
  local os_id="${1:-${OS_ID:-}}"
  local os_version="${2:-${OS_VERSION_ID:-}}"
  # Tumbleweed is a rolling release; its VERSION_ID is a snapshot date.
  [[ "${os_id}" == "opensuse-tumbleweed" ]] && return 0
  [[ "${os_version}" =~ ^[0-9]+$ ]] || return 1
  case "${os_id}" in
    centos) ((os_version >= 7 && os_version <= 10)) ;;
    rocky|almalinux|rhel|ol) ((os_version >= 8 && os_version <= 10)) ;;
    # Amazon Linux 2 is EL7-based and reports "2"; only 2023 is supported.
    amzn) ((os_version == 2023)) ;;
    ubuntu) ((os_version >= 22 && os_version <= 26)) ;;
    debian) ((os_version >= 11 && os_version <= 13)) ;;
    opensuse-leap|sles) ((os_version >= 15 && os_version <= 16)) ;;
    *) return 0 ;;
  esac
}

supported_os_summary() {
  printf '%s' \
'Ubuntu 22-26, Debian 11-13, CentOS Stream 7-10, Rocky Linux / AlmaLinux 8-10, \
RHEL 8-10, Oracle Linux 8-10, Amazon Linux 2023, openSUSE Leap / SLES 15-16, \
openSUSE Tumbleweed'
}

validate_supported_os_version() {
  supported_os_version && return 0
  case "${OS_ID:-}" in
    centos) die "Only CentOS 7-10 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    rocky|almalinux) die "Only Rocky Linux / AlmaLinux 8-10 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    rhel) die "Only RHEL 8-10 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    ol) die "Only Oracle Linux 8-10 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    amzn) die "Only Amazon Linux 2023 is supported; detected version: ${OS_VERSION_ID:-unknown}. Amazon Linux 2 is EL7-based and out of scope" ;;
    ubuntu) die "Only Ubuntu 22-26 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    debian) die "Only Debian 11-13 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    opensuse-leap|sles) die "Only openSUSE Leap / SLES 15-16 is supported; detected version: ${OS_VERSION_ID:-unknown}" ;;
    *) die "Unable to identify the operating system version: ${OS_ID:-unknown} ${OS_VERSION_ID:-unknown}" ;;
  esac
}

# OS_ID, OS_ID_LIKE, OS_VERSION_ID, OS_FAMILY, ARCH, and PM are read by the
# per-package-manager modules and by the installer steps.
# shellcheck disable=SC2034
detect_os() {
  [[ -f "${LNMP_OS_RELEASE_FILE}" ]] || die "Only Linux distributions with ${LNMP_OS_RELEASE_FILE} are supported"
  OS_ID="$(os_release_value ID | tr '[:upper:]' '[:lower:]' || true)"
  OS_ID_LIKE="$(os_release_value ID_LIKE | tr '[:upper:]' '[:lower:]' || true)"
  OS_VERSION_ID="$(os_release_value VERSION_ID || true)"
  OS_VERSION_ID="${OS_VERSION_ID%%.*}"
  ARCH="$(uname -m)"
  [[ -n "${OS_ID}" ]] || die "${LNMP_OS_RELEASE_FILE} does not define ID; cannot identify the distribution"

  if OS_FAMILY="$(os_family_for_id "${OS_ID}")"; then
    :
  elif OS_FAMILY="$(os_family_for_id_like "${OS_ID_LIKE}")"; then
    if [[ "${LNMP_DERIVATIVE_NOTICE_SHOWN:-}" != "1" ]]; then
      warn "Unrecognised distribution '${OS_ID}'; treating it as ${OS_FAMILY}-compatible based on ID_LIKE='${OS_ID_LIKE}'"
      warn "Verified distributions: $(supported_os_summary)"
      LNMP_DERIVATIVE_NOTICE_SHOWN=1
    fi
  else
    die "Unsupported operating system: ${OS_ID}. Supported: $(supported_os_summary)"
  fi

  PM="$(package_manager_for_family "${OS_FAMILY}")" ||
    die "No supported package manager for ${OS_ID} (family ${OS_FAMILY})"
  validate_supported_os_version
}
