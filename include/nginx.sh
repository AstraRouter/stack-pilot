#!/usr/bin/env bash

install_nginx() {
  if [[ -x "${nginx_install_dir}/sbin/nginx" ]]; then
    local detected
    detected="$(${nginx_install_dir}/sbin/nginx -v 2>&1 | extract_semver || true)"
    if should_skip_completed_install Nginx "${nginx_install_dir}" "${nginx_ver}" "${detected}"; then
      warn "Nginx is already installed: ${nginx_install_dir}"
      write_nginx_service
      systemctl_reload_or_restart nginx
      verify_nginx_service
      return 0
    fi
  fi

  download_src "${nginx_url}" "${nginx_url##*/}" "${nginx_sha256:-}"
  local build_dir archive
  archive="${LNMP_SRC_DIR}/${nginx_url##*/}"
  build_dir="$(make_build_dir)"
  extract_archive "${archive}" "${build_dir}"

  pushd "${build_dir}/nginx-${nginx_ver}" >/dev/null
  ./configure \
    --prefix="${nginx_install_dir}" \
    --user="${user}" \
    --group="${group}" \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_gzip_static_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-stream \
    --with-stream_ssl_module
  make -j"$(build_parallelism)"
  make install
  popd >/dev/null
  rm -rf "${build_dir}"
  write_component_version_marker "${nginx_install_dir}" "${nginx_ver}"

  init_layout_dirs
  mkdir -p "${nginx_install_dir}/conf/vhost" "${wwwroot_dir}/default" "${nginx_log_dir}"
  write_nginx_main_conf
  write_nginx_service
  link_executable_to_bin "${nginx_install_dir}/sbin/nginx" nginx
  systemctl_reload_or_restart nginx
  verify_nginx_service
}

write_nginx_main_conf() {
  cat > "${nginx_install_dir}/conf/nginx.conf" <<EOF
user ${user} ${group};
worker_processes auto;
worker_rlimit_nofile 65535;
error_log ${nginx_log_dir}/error.log warn;
pid ${nginx_pid};

events {
    worker_connections ${nginx_worker_connections};
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    server_tokens off;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log ${nginx_log_dir}/access.log main;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout ${nginx_keepalive_timeout};
    gzip on;

    include ${nginx_install_dir}/conf/vhost/*.conf;
}
EOF

  cat > "${nginx_install_dir}/conf/vhost/default.conf" <<EOF
server {
    listen ${nginx_http_port} default_server;
    server_name _;
    root ${wwwroot_dir}/default;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  printf 'LNMP installed\n' > "${wwwroot_dir}/default/index.html"
}

write_nginx_service() {
  local unit_dir="${LNMP_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  mkdir -p "${unit_dir}"
  cat > "${unit_dir}/nginx.service" <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${nginx_install_dir}/sbin/nginx -t
ExecStart=${nginx_install_dir}/sbin/nginx -g "daemon off;"
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -QUIT \$MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=30
Restart=on-failure
RestartSec=2
LimitNOFILE=65535
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

verify_nginx_service() {
  "${nginx_install_dir}/sbin/nginx" -t || die "Nginx configuration validation failed"
  if command_exists systemctl; then
    systemctl is-active --quiet nginx || die "Nginx did not remain active after startup"
  fi
}
