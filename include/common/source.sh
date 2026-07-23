#!/usr/bin/env bash

source_cache_path() {
  local url="$1"
  local output="${2:-${url##*/}}"
  printf '%s/%s' "${LNMP_SRC_DIR}" "${output}"
}

source_cache_state() {
  local url="$1"
  local output="${2:-${url##*/}}"
  local file
  file="$(source_cache_path "${url}" "${output}")"
  if [[ -s "${file}" ]]; then
    printf 'downloaded'
  else
    printf 'not downloaded'
  fi
}

download_src() {
  local url="$1"
  local output="${2:-${url##*/}}"
  local checksum="${3:-}"
  local target tmp
  mkdir -p "${LNMP_SRC_DIR}"
  target="${LNMP_SRC_DIR}/${output}"
  tmp="${target}.part"
  if [[ -s "${target}" ]]; then
    ok "[${output}] already exists"
    if [[ -n "${checksum}" ]]; then
      verify_sha256 "${target}" "${checksum}"
    fi
    return 0
  fi
  info "Downloading ${url}"
  rm -f "${tmp}"
  if command_exists curl; then
    curl -fL --proto-redir '=https' --retry 3 \
      --connect-timeout 15 --speed-limit 1024 --speed-time 30 -o "${tmp}" "${url}"
  elif command_exists wget; then
    wget --timeout=30 --tries=3 --retry-connrefused -O "${tmp}" "${url}"
  else
    die "curl or wget is required to download source archives"
  fi
  if [[ -n "${checksum}" ]]; then
    verify_sha256 "${tmp}" "${checksum}" || {
      rm -f "${tmp}"
      die "SHA256 verification failed: ${output}"
    }
  fi
  mv "${tmp}" "${target}"
  return 0
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  [[ -f "${file}" ]] || return 1
  if command_exists sha256sum; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  fi
  [[ "${actual}" == "${expected}" ]]
}

extract_archive() {
  local archive="$1"
  local destination="$2"
  mkdir -p "${destination}"
  case "${archive}" in
    *.tar.gz|*.tgz) tar xzf "${archive}" -C "${destination}" ;;
    *.tar.xz) tar xJf "${archive}" -C "${destination}" ;;
    *.tar.bz2) tar xjf "${archive}" -C "${destination}" ;;
    *) die "Unsupported archive format: ${archive}" ;;
  esac
}
