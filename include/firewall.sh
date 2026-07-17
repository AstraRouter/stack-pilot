#!/usr/bin/env bash

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"
  if command_exists ufw; then
    ufw allow "${port}/${proto}" || true
  elif command_exists firewall-cmd; then
    firewall-cmd --permanent --add-port="${port}/${proto}" || true
    firewall-cmd --reload || true
  else
    warn "ufw/firewalld was not detected; skipping firewall port ${port}/${proto}"
  fi
}

configure_firewall() {
  [[ "${manage_firewall:-n}" == "y" ]] || return 0
  open_firewall_port "${nginx_http_port:-80}" tcp
  open_firewall_port "${nginx_https_port:-443}" tcp
  [[ "${open_database_port:-n}" == "y" && "${db_engine}" == "mysql" ]] && open_firewall_port "${mysql_port:-3306}" tcp
  [[ "${open_database_port:-n}" == "y" && "${db_engine}" == "mariadb" ]] && open_firewall_port "${mariadb_port:-3306}" tcp
  [[ "${open_redis_port:-n}" == "y" ]] && open_firewall_port "${redis_port:-6379}" tcp
  [[ "${open_memcached_port:-n}" == "y" ]] && open_firewall_port "${memcached_port:-11211}" tcp
}
