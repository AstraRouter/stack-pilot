#!/usr/bin/env bash

domain_dns_addresses() {
  local domain="$1" output=""
  if command_exists getent; then
    output="$(getent ahosts "${domain}" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++' || true)"
  elif command_exists dig; then
    output="$({ dig +short A "${domain}"; dig +short AAAA "${domain}"; } 2>/dev/null | awk 'NF && !seen[$0]++' || true)"
  elif command_exists host; then
    output="$(host "${domain}" 2>/dev/null | awk '/has address|has IPv6 address/ {print $NF}' | awk '!seen[$0]++' || true)"
  else
    return 2
  fi
  [[ -n "${output}" ]] || return 1
  printf '%s\n' "${output}"
}

fetch_http_challenge() {
  local domain="$1" challenge_name="$2"
  curl -fsSL --max-redirs 10 --connect-timeout 5 --max-time 15 \
    "http://${domain}/.well-known/acme-challenge/${challenge_name}"
}

cleanup_ssl_preflight_file() {
  local challenge_file="$1" challenge_dir="$2"
  [[ -f "${challenge_file}" ]] && rm -f -- "${challenge_file}"
  rmdir "${challenge_dir}" 2>/dev/null || true
  rmdir "$(dirname "${challenge_dir}")" 2>/dev/null || true
}

preflight_ssl_certificate() {
  local domain="$1" aliases="${2:-}" root_dir="$3"
  local candidate addresses dns_status response error="" challenge_dir challenge_name challenge_file token
  command_exists curl || die "Certificate preflight requires curl; run the installer's dependency stage first"
  [[ -d "${root_dir}" ]] || die "Certificate web root does not exist: ${root_dir}"

  challenge_dir="${root_dir}/.well-known/acme-challenge"
  challenge_name="stack-pilot-preflight-$$-${RANDOM:-0}"
  challenge_file="${challenge_dir}/${challenge_name}"
  token="stack-pilot:${challenge_name}"
  mkdir -p "${challenge_dir}"
  printf '%s' "${token}" > "${challenge_file}"

  for candidate in ${domain} ${aliases}; do
    dns_status=0
    addresses="$(domain_dns_addresses "${candidate}" 2>/dev/null)" || dns_status=$?
    if ((dns_status == 2)); then
      error="DNS preflight cannot run because getent, dig, and host are unavailable"
      break
    fi
    if ((dns_status != 0)) || [[ -z "${addresses}" ]]; then
      error="${candidate} does not resolve to an A or AAAA record. Add an A/AAAA record or a resolvable CNAME, or remove the unused alias from the certificate request"
      break
    fi
    response="$(fetch_http_challenge "${candidate}" "${challenge_name}" 2>/dev/null || true)"
    if [[ "${response}" != "${token}" ]]; then
      error="The HTTP-01 challenge URL is not publicly reachable at http://${candidate}/.well-known/acme-challenge/${challenge_name}. Verify DNS, the active Nginx virtual host, and public port 80 access"
      break
    fi
    ok "Certificate preflight passed for ${candidate} (DNS and HTTP-01 webroot)"
  done

  cleanup_ssl_preflight_file "${challenge_file}" "${challenge_dir}"
  [[ -z "${error}" ]] || die "${error}"
}

link_ssl_certificate() {
  local domain="$1"
  local target_dir
  target_dir="$(ssl_cert_dir "${domain}")"
  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] || die "Certificate file does not exist: /etc/letsencrypt/live/${domain}/fullchain.pem"
  [[ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]] || die "Certificate private key does not exist: /etc/letsencrypt/live/${domain}/privkey.pem"
  mkdir -p "${target_dir}"
  ln -sfn "/etc/letsencrypt/live/${domain}/fullchain.pem" "${target_dir}/fullchain.pem"
  ln -sfn "/etc/letsencrypt/live/${domain}/privkey.pem" "${target_dir}/privkey.pem"
}

issue_ssl_certificate() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local email="$4"
  local cert_args=(-d "${domain}")
  local alias
  for alias in ${aliases}; do
    cert_args+=(-d "${alias}")
  done
  if [[ "${LNMP_SKIP_SSL_PREFLIGHT:-0}" != "1" ]]; then
    preflight_ssl_certificate "${domain}" "${aliases}" "${root_dir}"
  fi
  command_exists certbot || die "Certbot is not installed; install it from the virtual-host menu or run install.sh"
  certbot certonly --webroot -w "${root_dir}" "${cert_args[@]}" --email "${email}" --agree-tos --non-interactive
  link_ssl_certificate "${domain}"
}

renew_all_certificates() {
  command_exists certbot || die "Certbot is not installed"
  certbot renew --deploy-hook "systemctl reload nginx"
}

list_certificate_status() {
  command_exists certbot || die "Certbot is not installed"
  certbot certificates
}
