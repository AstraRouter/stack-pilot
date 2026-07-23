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
  download_src "https://getcomposer.org/installer" "composer-setup.php"
  cp "${LNMP_SRC_DIR}/composer-setup.php" "${installer}"
  if command_exists curl; then
    checksum="$(curl -fsSL --proto '=https' https://composer.github.io/installer.sig || true)"
  elif command_exists wget; then
    checksum="$(wget -qO- --https-only https://composer.github.io/installer.sig || true)"
  fi
  [[ -n "${checksum}" ]] || die "Unable to fetch the Composer installer signature; refusing to run an unverified installer"
  actual="$("${php_bin}" -r "echo hash_file('sha384', '${installer}');" 2>/dev/null || true)"
  [[ -n "${actual}" && "${checksum}" == "${actual}" ]] || die "Composer installer checksum mismatch"
  "${php_bin}" "${installer}" --install-dir="${composer_install_dir}" --filename=composer
  mkdir -p "${LNMP_CLI_BIN_DIR:-/usr/local/bin}"
  ln -sf "${target}" "${LNMP_CLI_BIN_DIR:-/usr/local/bin}/composer"
  rm -f "${installer}"
}
