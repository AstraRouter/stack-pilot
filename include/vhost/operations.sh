#!/usr/bin/env bash

list_vhosts() {
  local dir
  dir="$(vhost_conf_dir)"
  [[ -d "${dir}" ]] || return 0
  find "${dir}" -maxdepth 1 -type f -name '*.conf' -exec basename {} .conf \; | sort
}

delete_vhost_config() {
  local domain="$1"
  rm -f "$(vhost_conf_file "${domain}")"
}

reload_nginx() {
  if [[ -x "${nginx_install_dir}/sbin/nginx" ]]; then
    "${nginx_install_dir}/sbin/nginx" -t
  fi
  if command_exists systemctl; then
    systemctl reload nginx
  else
    "${nginx_install_dir}/sbin/nginx" -s reload
  fi
}

# Install a freshly rendered vhost config atomically: validate the whole Nginx
# configuration with `nginx -t`, then roll back to the previous file (or remove a
# new one) if validation fails, so a bad render can never take down every site.
install_vhost_config() {
  local conf="$1" candidate="$2"
  local backup="" nginx_bin="${nginx_install_dir:-}/sbin/nginx"
  if [[ -f "${conf}" ]]; then
    backup="${conf}.stackpilot-bak.$$"
    cp -a "${conf}" "${backup}"
  fi
  mv -- "${candidate}" "${conf}"
  if [[ -x "${nginx_bin}" ]] && ! "${nginx_bin}" -t >/dev/null 2>&1; then
    if [[ -n "${backup}" ]]; then
      mv -- "${backup}" "${conf}"
    else
      rm -f -- "${conf}"
    fi
    warn "Nginx rejected the generated configuration; the previous state was restored. Details:"
    "${nginx_bin}" -t 2>&1 | tail -20 >&2 || true
    die "Aborting: the generated site configuration ${conf##*/} is invalid"
  fi
  [[ -n "${backup}" ]] && rm -f -- "${backup}"
  return 0
}

switch_vhost_php_version() {
  local domain="$1"
  local php_version="$2"
  local conf port
  conf="$(vhost_conf_file "${domain}")"
  [[ -f "${conf}" ]] || die "Virtual host configuration does not exist: ${domain}"
  port="$(php_fpm_port "${php_version}")"
  sed -i.bak -E "s@fastcgi_pass 127\.0\.0\.1:[0-9]+;@fastcgi_pass 127.0.0.1:${port};@g" "${conf}"
}
