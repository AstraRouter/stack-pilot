#!/usr/bin/env bash

# shellcheck source=/dev/null
source "${LNMP_ROOT_DIR}/include/nginx/policy.sh"

# Optional build flags that depend on the selected version and options.conf.
nginx_configure_extra_flags() {
  nginx_http3_configured || return 0
  printf '%s\n' --with-http_v3_module
}

install_nginx() {
  if [[ -x "${nginx_install_dir}/sbin/nginx" ]]; then
    local detected
    detected="$("${nginx_install_dir}/sbin/nginx" -v 2>&1 | extract_semver || true)"
    if should_skip_completed_install Nginx "${nginx_install_dir}" "${nginx_ver}" "${detected}"; then
      warn "Nginx is already installed: ${nginx_install_dir}"
      write_nginx_service
      systemctl_reload_or_restart nginx
      verify_nginx_service
      return 0
    fi
  fi

  # user and group are written into nginx.conf and passed to ./configure, and
  # options.conf can set them without going through the wizard.
  validate_unix_username "${user}" || die "Invalid service user: ${user}"
  validate_unix_username "${group}" || die "Invalid service group: ${group}"
  assert_http3_supported

  download_src "${nginx_url}" "${nginx_url##*/}" "${nginx_sha256:-}"
  local build_dir archive extra_flag
  local configure_flags=(
    "--prefix=${nginx_install_dir}"
    "--user=${user}"
    "--group=${group}"
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_gzip_static_module
    --with-http_realip_module
    --with-http_stub_status_module
    --with-stream
    --with-stream_ssl_module
  )
  while IFS= read -r extra_flag; do
    [[ -n "${extra_flag}" ]] && configure_flags+=("${extra_flag}")
  done < <(nginx_configure_extra_flags)
  archive="${LNMP_SRC_DIR}/${nginx_url##*/}"
  build_dir="$(make_build_dir)"
  extract_archive "${archive}" "${build_dir}"

  pushd "${build_dir}/nginx-${nginx_ver}" >/dev/null || die "Could not enter the build directory"
  ./configure "${configure_flags[@]}"
  make -j"$(build_parallelism)"
  make install
  popd >/dev/null || die "Could not leave the build directory"
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
  local worker_connections keepalive_timeout
  validate_unix_username "${user}" || die "Invalid service user: ${user}"
  validate_unix_username "${group}" || die "Invalid service group: ${group}"
  # Both land unquoted in nginx.conf, where an empty or malformed value produces
  # a directive Nginx refuses to parse. The status is checked explicitly rather
  # than left to set -e, which is suppressed inside an if condition.
  worker_connections="$(nginx_option_integer "${nginx_worker_connections:-10240}" 1048576)" ||
    die "Invalid nginx_worker_connections: ${nginx_worker_connections} (expected an integer from 1 through 1048576)"
  keepalive_timeout="$(nginx_option_integer "${nginx_keepalive_timeout:-65}" 86400)" ||
    die "Invalid nginx_keepalive_timeout: ${nginx_keepalive_timeout} (expected seconds from 1 through 86400)"
  assert_nginx_policy_options
  # access_log here is the fallback for server blocks that define none of their
  # own; a virtual host with its own access_log replaces it rather than adding
  # a second entry, because Nginx inherits these directives only when the
  # current level defines none.
  cat > "${nginx_install_dir}/conf/nginx.conf" <<EOF
user ${user} ${group};
worker_processes auto;
worker_rlimit_nofile 65535;
error_log ${nginx_log_dir}/error.log warn;
pid ${nginx_pid};

events {
    worker_connections ${worker_connections};
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
    keepalive_timeout ${keepalive_timeout};

    # Nginx refuses a larger body with 413 before PHP is reached, so this must
    # not be smaller than php_post_max_size.
    client_max_body_size $(nginx_body_size_limit);

    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml text/javascript application/javascript
               application/json application/xml application/rss+xml
               image/svg+xml font/woff font/woff2;
$(nginx_rate_limit_zone_block)
    include ${nginx_install_dir}/conf/vhost/*.conf;
}
EOF

  cat > "${nginx_install_dir}/conf/vhost/default.conf" <<EOF
server {
    listen ${nginx_http_port} default_server;
    server_name _;
    root ${wwwroot_dir}/default;
    index index.html index.htm;$(nginx_security_header_lines http)

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  # Only seed the placeholder page. Rewriting it on every run would replace a
  # real landing page during an Nginx upgrade.
  [[ -e "${wwwroot_dir}/default/index.html" ]] ||
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
