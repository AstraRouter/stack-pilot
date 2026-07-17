#!/usr/bin/env bash

php_configure_flags_for_extensions() {
  local short="$1"
  local extensions="$2"
  local ext
  for ext in ${extensions}; do
    if ! php_builtin_extension_supported "${short}" "${ext}"; then
      warn "PHP ${short}: skipping incompatible built-in extension ${ext}" >&2
      continue
    fi
    case "${ext}" in
      opcache) printf '%s\n' "--enable-opcache" ;;
      mysqli) printf '%s\n' "--with-mysqli=mysqlnd" ;;
      pdo_mysql) printf '%s\n' "--with-pdo-mysql=mysqlnd" ;;
      mbstring) printf '%s\n' "--enable-mbstring" ;;
      curl) printf '%s\n' "--with-curl" ;;
      openssl) printf '%s\n' "--with-openssl" ;;
      gd)
        if [[ "${short}" =~ ^(54|55|56|70|71|72|73|74)$ ]]; then
          printf '%s\n' "--with-gd" "--with-jpeg-dir" "--with-png-dir" "--with-freetype-dir"
        else
          printf '%s\n' "--enable-gd" "--with-jpeg" "--with-freetype"
        fi
        ;;
      zip) printf '%s\n' "--with-zip" ;;
      fileinfo) printf '%s\n' "--enable-fileinfo" ;;
      exif) printf '%s\n' "--enable-exif" ;;
      intl) printf '%s\n' "--enable-intl" ;;
      bcmath) printf '%s\n' "--enable-bcmath" ;;
      sockets) printf '%s\n' "--enable-sockets" ;;
      pcntl) printf '%s\n' "--enable-pcntl" ;;
      soap) printf '%s\n' "--enable-soap" ;;
      ldap) printf '%s\n' "--with-ldap" ;;
      imap) printf '%s\n' "--with-imap" "--with-imap-ssl" ;;
      xsl) printf '%s\n' "--with-xsl" ;;
      gettext) printf '%s\n' "--with-gettext" ;;
      gmp) printf '%s\n' "--with-gmp" ;;
      calendar) printf '%s\n' "--enable-calendar" ;;
      shmop) printf '%s\n' "--enable-shmop" ;;
      sysvsem) printf '%s\n' "--enable-sysvsem" ;;
      sysvshm) printf '%s\n' "--enable-sysvshm" ;;
      sysvmsg) printf '%s\n' "--enable-sysvmsg" ;;
      ftp) printf '%s\n' "--enable-ftp" ;;
      bz2) printf '%s\n' "--with-bz2" ;;
      sodium) printf '%s\n' "--with-sodium" ;;
      readline) printf '%s\n' "--with-readline" ;;
      ffi) printf '%s\n' "--with-ffi" ;;
      posix) printf '%s\n' "--enable-posix" ;;
      dba) printf '%s\n' "--enable-dba" ;;
      tidy) printf '%s\n' "--with-tidy" ;;
      snmp) printf '%s\n' "--with-snmp" ;;
      pgsql) printf '%s\n' "--with-pgsql" ;;
      pdo_pgsql) printf '%s\n' "--with-pdo-pgsql" ;;
    esac
  done
}
