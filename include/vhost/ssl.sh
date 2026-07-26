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

LNMP_LETSENCRYPT_LIVE_DIR="${LNMP_LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}"

link_ssl_certificate() {
  local domain="$1"
  local target_dir lineage
  # --cert-name pins the lineage to the domain, but a directory left by an
  # earlier run without it may carry a -0001 suffix. Prefer the exact name and
  # fall back to the newest suffixed lineage.
  lineage="${LNMP_LETSENCRYPT_LIVE_DIR}/${domain}"
  if [[ ! -f "${lineage}/fullchain.pem" ]]; then
    lineage="$(find "${LNMP_LETSENCRYPT_LIVE_DIR}" -maxdepth 1 -type d -name "${domain}-[0-9][0-9][0-9][0-9]" 2>/dev/null | sort | tail -1)"
  fi
  [[ -n "${lineage}" && -f "${lineage}/fullchain.pem" ]] ||
    die "Certificate file does not exist: ${LNMP_LETSENCRYPT_LIVE_DIR}/${domain}/fullchain.pem"
  [[ -f "${lineage}/privkey.pem" ]] ||
    die "Certificate private key does not exist: ${lineage}/privkey.pem"
  target_dir="$(ssl_cert_dir "${domain}")"
  mkdir -p "${target_dir}"
  ln -sfn "${lineage}/fullchain.pem" "${target_dir}/fullchain.pem"
  ln -sfn "${lineage}/privkey.pem" "${target_dir}/privkey.pem"
}

# Let's Encrypt allows 5 duplicate certificates per week. Re-running the wizard
# for an unchanged site must not consume that budget, so a still-valid
# certificate is reused and only a changed domain set triggers a reissue.
issue_ssl_certificate() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local email="$4"
  local cert_args=(-d "${domain}")
  local alias output status=0
  for alias in ${aliases}; do
    cert_args+=(-d "${alias}")
  done
  if [[ "${LNMP_SKIP_SSL_PREFLIGHT:-0}" != "1" ]]; then
    preflight_ssl_certificate "${domain}" "${aliases}" "${root_dir}"
  fi
  command_exists certbot || die "Certbot is not installed; install it from the virtual-host menu or run install.sh"

  output="$(certbot certonly --webroot -w "${root_dir}" "${cert_args[@]}" \
    --cert-name "${domain}" --keep-until-expiring --expand \
    --email "${email}" --agree-tos --non-interactive 2>&1)" || status=$?
  printf '%s\n' "${output}"

  if ((status != 0)); then
    if printf '%s' "${output}" | grep -qi 'too many certificates\|rate limit'; then
      warn "Let's Encrypt rate limit reached for ${domain}; no new certificate was issued."
      warn "The limit is 5 duplicate certificates per week. Retry after it resets."
    else
      warn "Certbot failed for ${domain}; see the output above."
    fi
    # An existing certificate from a previous run is still usable.
    link_ssl_certificate "${domain}" 2>/dev/null && {
      warn "An existing certificate for ${domain} was found and will be reused."
      return 0
    }
    return 1
  fi
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
