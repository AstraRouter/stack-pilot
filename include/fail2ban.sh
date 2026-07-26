#!/usr/bin/env bash

# The nginx-limit-req jail only makes sense alongside the rate-limit option, so
# this module needs the same policy helpers the vhost renderer uses.
# shellcheck source=/dev/null
source "${LNMP_ROOT_DIR}/include/nginx/policy.sh"

# Brute-force protection. Nginx rate limiting (see include/nginx/policy.sh)
# slows an attacker down per request; fail2ban removes them from the host
# entirely for a while. The filters used here ship with fail2ban itself, so only
# the jails and the log paths this installer creates need to be declared.

fail2ban_jail_path() {
  printf '%s' "${LNMP_FAIL2BAN_JAIL_FILE:-/etc/fail2ban/jail.d/stack-pilot.local}"
}

# Validated before rendering rather than during it: the emitters below run
# inside $( ), where a die would only end the substitution and leave a jail file
# with a blank setting.
assert_fail2ban_options() {
  local name
  for name in fail2ban_bantime fail2ban_findtime; do
    validate_positive_integer "${!name:-1}" 31536000 ||
      die "Invalid ${name}: ${!name} (expected seconds from 1 through 31536000)"
  done
  validate_positive_integer "${fail2ban_maxretry:-5}" 1000 ||
    die "Invalid fail2ban_maxretry: ${fail2ban_maxretry} (expected an integer from 1 through 1000)"
}

render_fail2ban_jails() {
  local backend="auto"
  assert_fail2ban_options
  # On systemd hosts sshd usually logs only to the journal, where a file backend
  # would silently match nothing.
  command_exists systemctl && backend="systemd"
  cat <<EOF
# Managed by Stack Pilot. Local edits are replaced on the next install run.
[DEFAULT]
bantime  = $((10#${fail2ban_bantime:-3600}))
findtime = $((10#${fail2ban_findtime:-600}))
maxretry = $((10#${fail2ban_maxretry:-5}))

[sshd]
enabled = true
backend = ${backend}
EOF
  has_component nginx || return 0
  cat <<EOF

[nginx-http-auth]
enabled = true
logpath = ${nginx_log_dir}/*error.log

[nginx-botsearch]
enabled = true
logpath = ${nginx_log_dir}/*access.log
EOF
  # This filter only matches the "limiting requests" lines that limit_req emits,
  # so it is pointless unless rate limiting is switched on.
  nginx_rate_limit_configured || return 0
  cat <<EOF

[nginx-limit-req]
enabled = true
logpath = ${nginx_log_dir}/*error.log
EOF
}

install_fail2ban() {
  local target
  detect_os
  if ! command_exists fail2ban-client; then
    case "${PM}" in
      # EPEL carries fail2ban on EL; Amazon Linux 2023 has it in its base repos.
      dnf|yum) install_packages epel-release || true ;;
    esac
    install_packages fail2ban || {
      warn "fail2ban could not be installed from the configured repositories; skipping the jail configuration"
      return 1
    }
  fi
  command_exists fail2ban-client || {
    warn "fail2ban installation completed without a fail2ban-client binary; skipping the jail configuration"
    return 1
  }
  target="$(fail2ban_jail_path)"
  mkdir -p "$(dirname "${target}")"
  render_fail2ban_jails > "${target}"
  chmod 644 "${target}"
  systemctl_reload_or_restart fail2ban || {
    warn "fail2ban did not restart with the generated jails; review ${target}"
    return 1
  }
  ok "fail2ban jails configured: ${target}"
}
