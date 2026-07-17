#!/usr/bin/env bash

php_profile_builtin_extensions() {
  case "${1:-web}" in
    minimal)
      printf '%s' "opcache mysqli pdo_mysql mbstring curl openssl"
      ;;
    web)
      printf '%s' "opcache mysqli pdo_mysql mbstring curl openssl gd zip fileinfo exif intl bcmath sockets pcntl bz2 sodium"
      ;;
    full)
      printf '%s' "opcache mysqli pdo_mysql mbstring curl openssl gd zip fileinfo exif intl bcmath sockets pcntl soap ldap imap xsl gettext gmp calendar shmop sysvsem sysvshm sysvmsg ftp bz2 sodium readline ffi posix dba tidy snmp pgsql pdo_pgsql"
      ;;
    custom)
      printf '%s' "${php_extensions:-}"
      ;;
    *)
      return 1
      ;;
  esac
}

php_profile_pecl_extensions() {
  case "${1:-web}" in
    minimal)
      printf '%s' ""
      ;;
    web)
      printf '%s' "redis imagick"
      ;;
    full)
      printf '%s' "redis memcached imagick swoole mongodb yaf yar apcu igbinary msgpack yaml uuid ssh2 rdkafka oauth"
      ;;
    custom)
      printf '%s' "${php_pecl_extensions:-}"
      ;;
    *)
      return 1
      ;;
  esac
}
