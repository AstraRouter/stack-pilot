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
$(php_open_basedir_directive)
EOF
}

# Emitting "open_basedir =" would clear a restriction set anywhere else, so the
# directive is written only when a value is actually configured.
php_open_basedir_directive() {
  [[ -n "${php_open_basedir:-}" ]] || return 0
  printf 'open_basedir = %s' "${php_open_basedir}"
}

apply_php_security() {
  local version
  [[ "${php_security_hardening:-y}" == "y" ]] || return 0
  for version in ${php_versions}; do
    [[ -d "$(php_install_dir_for_version "${version}")" ]] && write_php_security_ini "${version}"
  done
}
