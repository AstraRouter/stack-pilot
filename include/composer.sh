#!/usr/bin/env bash

install_composer() {
  local target installer checksum actual php_bin first_php
  target="${composer_install_dir}/composer"
  if [[ -x "${target}" ]]; then
    warn "Composer is already installed: ${target}"
    return 0
  fi
  mkdir -p "${composer_install_dir}"
  installer="$(mktemp)"
  php_bin="$(command -v php || true)"
  if [[ -z "${php_bin}" ]]; then
    first_php="${php_versions%% *}"
    php_bin="$(php_install_dir_for_version "${first_php}")/bin/php"
  fi
  [[ -x "${php_bin}" ]] || die "Composer requires an executable PHP binary; install PHP or add php to PATH first"
  # Removed on the success path below rather than through a RETURN trap: such a
  # trap stays installed after this function returns and fires again when
  # run_step_once returns, where ${installer} no longer exists. The die paths
  # end the process, so the temporary file they leave behind goes with it.
  # Both halves must come from the same moment: the signature is always fetched
  # fresh, so a cached installer from an older release could never match it
  # again once upstream published a new one.
  download_uncached "https://getcomposer.org/installer" "${installer}"
  if command_exists curl; then
    checksum="$(curl -fsSL --proto '=https' https://composer.github.io/installer.sig || true)"
  elif command_exists wget; then
    checksum="$(wget -qO- --https-only https://composer.github.io/installer.sig || true)"
  fi
  [[ -n "${checksum}" ]] || die "Unable to fetch the Composer installer signature; refusing to run an unverified installer"
  actual="$("${php_bin}" -r "echo hash_file('sha384', '${installer}');" 2>/dev/null || true)"
  [[ -n "${actual}" && "${checksum}" == "${actual}" ]] ||
    die "Composer installer checksum mismatch: expected ${checksum:-unknown}, got ${actual:-none}. Both files were just downloaded, so this points at a broken download or a tampered mirror rather than a stale cache"
  "${php_bin}" "${installer}" --install-dir="${composer_install_dir}" --filename=composer
  mkdir -p "${LNMP_CLI_BIN_DIR:-/usr/local/bin}"
  ln -sf "${target}" "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/composer"
  rm -f "${installer}"
}
