#!/usr/bin/env bash

reset_redis_config_password() {
  local conf="$1"
  local password="${2:-}"
  local tmp
  [[ -f "${conf}" ]] || die "Redis configuration does not exist: ${conf}"
  tmp="$(mktemp)"
  if [[ -n "${password}" ]]; then
    awk -v password="${password}" '
      BEGIN { done=0 }
      /^[[:space:]]*requirepass[[:space:]]+/ {
        if (!done) {
          print "requirepass " password
          done=1
        }
        next
      }
      { print }
      END {
        if (!done) print "requirepass " password
      }
    ' "${conf}" > "${tmp}"
  else
    awk '!/^[[:space:]]*requirepass[[:space:]]+/' "${conf}" > "${tmp}"
  fi
  mv "${tmp}" "${conf}"
}

reset_redis_password() {
  local password="${1:-}"
  local conf="${redis_install_dir}/etc/redis.conf"
  [[ -f "${conf}" ]] || die "Redis configuration does not exist: ${conf}"
  # Without this an unquoted space, '#', or newline silently corrupts
  # redis.conf and the server fails to start on the next restart.
  validate_redis_password "${password}" ||
    die "Invalid Redis password: use 6-512 characters from A-Z a-z 0-9 . _ ~ ! @ % ^ * + = : , / - (no spaces, quotes, or #)"
  reset_redis_config_password "${conf}" "${password}"
  chown root:redis "${conf}" 2>/dev/null || true
  chmod 640 "${conf}"
  redis_password="${password}"
  write_redis_auth_env "${password}"
  write_redis_service
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart redis-server >/dev/null 2>&1 || {
    systemctl kill redis-server >/dev/null 2>&1 || true
    pkill -TERM -f "${redis_install_dir}/bin/redis-server" >/dev/null 2>&1 || true
    sleep 2
    systemctl start redis-server
  }
}
