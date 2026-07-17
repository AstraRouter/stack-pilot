#!/usr/bin/env bash

php_builtin_extension_entries() {
  cat <<'EOF'
opcache|OPcache bytecode cache
mysqli|mysqli
pdo_mysql|PDO MySQL
mbstring|Multibyte string support
curl|curl
openssl|openssl
gd|GD image processing
zip|zip
fileinfo|File type detection
exif|Image metadata
intl|Internationalization
bcmath|Arbitrary-precision mathematics
sockets|sockets
pcntl|CLI process control
soap|soap
ldap|ldap
imap|imap
xsl|xsl
gettext|gettext
gmp|gmp
calendar|calendar
shmop|shmop
sysvsem|sysvsem
sysvshm|sysvshm
sysvmsg|sysvmsg
ftp|ftp
bz2|bzip2 compression
sodium|Modern cryptography (PHP 7.2+)
readline|Interactive CLI editing
ffi|FFI (PHP 7.4+)
posix|POSIX
dba|DBA database abstraction
tidy|HTML Tidy
snmp|SNMP
pgsql|PostgreSQL
pdo_pgsql|PDO PostgreSQL
EOF
}

php_pecl_extension_entries() {
  cat <<'EOF'
redis|redis
memcached|memcached
memcache|Legacy application compatibility
imagick|imagick
swoole|swoole
xdebug|xdebug
mongodb|mongodb
yaf|yaf
yar|yar
protobuf|protobuf
grpc|grpc
event|event
amqp|amqp
apcu|apcu
igbinary|Efficient serialization
msgpack|MessagePack serialization
yaml|yaml
uuid|uuid
ssh2|ssh2
rdkafka|Kafka client
oauth|OAuth
ioncube|ionCube Loader
EOF
}

php_builtin_extension_supported() {
  local short="${1//./}" ext="$2"
  case "${ext}" in
    sodium) ((10#${short} >= 72)) ;;
    ffi) ((10#${short} >= 74)) ;;
    imap)
      ((10#${short} < 84)) && php_imap_build_supported_for_system
      ;;
    *) return 0 ;;
  esac
}

php_pecl_extension_supported() {
  local short="${1//./}" ext="$2"
  case "${ext}" in
    grpc|protobuf|rdkafka) ((10#${short} >= 70)) ;;
    yaml|uuid|ssh2|oauth) ((10#${short} >= 70)) ;;
    igbinary|msgpack|apcu) ((10#${short} >= 56)) ;;
    event) ((10#${short} >= 56)) ;;
    ioncube) return 1 ;;
    *) return 0 ;;
  esac
}

php_extension_allowed_values() {
  php_builtin_extension_entries | awk -F'|' '{print $1}' | xargs
}

php_pecl_allowed_values() {
  php_pecl_extension_entries | awk -F'|' '{print $1}' | xargs
}

php_extension_entries_args() {
  php_builtin_extension_entries
}

php_pecl_entries_args() {
  php_pecl_extension_entries
}
