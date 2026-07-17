#!/usr/bin/env bash

vhost_conf_dir() {
  printf '%s/conf/vhost' "${nginx_install_dir}"
}

vhost_conf_file() {
  local domain="$1"
  printf '%s/%s.conf' "$(vhost_conf_dir)" "${domain}"
}

ssl_cert_dir() {
  local domain="$1"
  printf '%s/conf/ssl/%s' "${nginx_install_dir}" "${domain}"
}

ssl_cert_fullchain_path() {
  local domain="$1"
  printf '%s/fullchain.pem' "$(ssl_cert_dir "${domain}")"
}

ssl_cert_key_path() {
  local domain="$1"
  printf '%s/privkey.pem' "$(ssl_cert_dir "${domain}")"
}

server_names() {
  local domain="$1"
  local aliases="${2:-}"
  if [[ -n "${aliases}" ]]; then
    printf '%s %s' "${domain}" "${aliases}"
  else
    printf '%s' "${domain}"
  fi
}
