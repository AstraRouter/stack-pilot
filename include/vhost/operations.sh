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

switch_vhost_php_version() {
  local domain="$1"
  local php_version="$2"
  local conf port
  conf="$(vhost_conf_file "${domain}")"
  [[ -f "${conf}" ]] || die "Virtual host configuration does not exist: ${domain}"
  port="$(php_fpm_port "${php_version}")"
  sed -i.bak -E "s@fastcgi_pass 127\.0\.0\.1:[0-9]+;@fastcgi_pass 127.0.0.1:${port};@g" "${conf}"
}
