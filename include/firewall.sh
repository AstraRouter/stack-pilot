#!/usr/bin/env bash

# Firewall management.
#
# Two rules shape this module. First, SSH is allowed before anything else:
# opening service ports and then enabling a firewall that drops the
# administrator's own session is the classic way to lose a remote host.
# Second, manage_firewall=y means the firewall is actually enabled -- adding
# rules to an inactive firewall looks like protection without providing any.

firewall_backend() {
  if command_exists ufw; then
    printf 'ufw'
  elif command_exists firewall-cmd; then
    printf 'firewalld'
  else
    return 1
  fi
}

# TCP ports sshd is reachable on. Sources, most to least authoritative:
#   1. SSH_CONNECTION - the port carrying this very session
#   2. sshd -T        - the effective config, including Include directives
#   3. sshd_config    - literal Port lines when sshd cannot be queried
#   4. 22             - fallback, so the list is never empty
sshd_listen_ports() {
  local ports=""
  local port config

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    # "client_ip client_port server_ip server_port"
    port="$(printf '%s' "${SSH_CONNECTION}" | awk '{print $4}')"
    validate_port "${port}" && ports="$(port_list_add_unique "${ports}" "${port}")"
  fi

  if command_exists sshd; then
    while read -r port; do
      validate_port "${port}" || continue
      ports="$(port_list_add_unique "${ports}" "${port}")"
    done < <(sshd -T 2>/dev/null | awk '/^port[[:space:]]+/ {print $2}' || true)
  fi

  if [[ -z "${ports}" ]]; then
    for config in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
      [[ -r "${config}" ]] || continue
      while read -r port; do
        validate_port "${port}" || continue
        ports="$(port_list_add_unique "${ports}" "${port}")"
      done < <(awk '/^[[:space:]]*[Pp]ort[[:space:]]+/ {print $2}' "${config}" 2>/dev/null || true)
    done
  fi

  [[ -n "${ports}" ]] || ports="22"
  printf '%s' "${ports}"
}

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"
  local backend
  if ! backend="$(firewall_backend)"; then
    warn "ufw/firewalld was not detected; skipping firewall port ${port}/${proto}"
    return 0
  fi
  case "${backend}" in
    ufw)
      ufw allow "${port}/${proto}" >/dev/null ||
        warn "Failed to allow ${port}/${proto} with ufw"
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null ||
        warn "Failed to allow ${port}/${proto} with firewalld"
      ;;
  esac
  return 0
}

firewall_is_active() {
  case "$(firewall_backend 2>/dev/null || true)" in
    ufw) LC_ALL=C ufw status 2>/dev/null | grep -qi '^Status: active' ;;
    firewalld) firewall-cmd --state >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

enable_firewall() {
  local backend
  backend="$(firewall_backend)" || return 0
  if firewall_is_active; then
    info "The ${backend} firewall is already active"
    return 0
  fi
  case "${backend}" in
    ufw)
      # --force skips the interactive prompt about disrupting SSH connections;
      # the SSH ports were allowed before this point.
      ufw --force enable >/dev/null || warn "Failed to enable ufw"
      ;;
    firewalld)
      systemctl enable --now firewalld >/dev/null 2>&1 || warn "Failed to enable firewalld"
      ;;
  esac
  firewall_is_active || warn "The ${backend} firewall could not be activated; rules were written but are not enforced"
  return 0
}

configure_firewall() {
  [[ "${manage_firewall:-n}" == "y" ]] || return 0
  local backend port ssh_ports
  if ! backend="$(firewall_backend)"; then
    warn "ufw/firewalld was not detected; no firewall rules were applied"
    return 0
  fi

  ssh_ports="$(sshd_listen_ports)"
  info "Allowing SSH on port(s) ${ssh_ports} before enabling the firewall"
  for port in ${ssh_ports}; do
    open_firewall_port "${port}" tcp
  done

  open_firewall_port "${nginx_http_port:-80}" tcp
  open_firewall_port "${nginx_https_port:-443}" tcp
  # QUIC runs over UDP on the same port; without this rule an HTTP/3 site simply
  # never negotiates h3 and silently stays on TCP.
  [[ "${nginx_http3:-n}" == "y" ]] && open_firewall_port "${nginx_https_port:-443}" udp
  if [[ "${open_database_port:-n}" == "y" ]]; then
    case "${db_engine:-none}" in
      mysql) open_firewall_port "${mysql_port:-3306}" tcp ;;
      mariadb) open_firewall_port "${mariadb_port:-3306}" tcp ;;
    esac
  fi
  [[ "${open_redis_port:-n}" == "y" ]] && open_firewall_port "${redis_port:-6379}" tcp
  [[ "${open_memcached_port:-n}" == "y" ]] && open_firewall_port "${memcached_port:-11211}" tcp

  if [[ "${backend}" == "firewalld" ]]; then
    firewall-cmd --reload >/dev/null || warn "Failed to reload firewalld rules"
  fi

  enable_firewall
  return 0
}
