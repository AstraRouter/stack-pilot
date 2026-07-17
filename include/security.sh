#!/usr/bin/env bash

write_php_security_ini() {
  local short="$1"
  local prefix
  prefix="$(php_install_dir_for_version "${short}")"
  mkdir -p "${prefix}/etc/php.d"
  cat > "${prefix}/etc/php.d/99-security.ini" <<EOF
expose_php = Off
display_errors = Off
log_errors = On
disable_functions = ${php_disable_functions}
open_basedir =
EOF
}

apply_php_security() {
  local version
  [[ "${php_security_hardening:-y}" == "y" ]] || return 0
  for version in ${php_versions}; do
    [[ -d "$(php_install_dir_for_version "${version}")" ]] && write_php_security_ini "${version}"
  done
}
