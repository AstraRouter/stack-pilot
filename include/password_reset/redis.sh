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
  reset_redis_config_password "${conf}" "${password}"
  redis_password="${password}"
  write_redis_service
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart redis-server >/dev/null 2>&1 || {
    systemctl kill redis-server >/dev/null 2>&1 || true
    pkill -TERM -f "${redis_install_dir}/bin/redis-server" >/dev/null 2>&1 || true
    sleep 2
    systemctl start redis-server
  }
}
