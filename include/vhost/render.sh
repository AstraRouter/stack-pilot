#!/usr/bin/env bash

php_fastcgi_block() {
  local enable_php="$1"
  local php_version="${2:-}"
  [[ "${enable_php}" == "y" ]] || return 0
  [[ -n "${php_version}" ]] || die "A PHP version is required when PHP is enabled"
  local port
  port="$(php_fpm_port "${php_version}")"
  cat <<EOF

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME \$fastcgi_script_name;
        fastcgi_pass 127.0.0.1:${port};
    }
EOF
}

vhost_try_files_rule() {
  local template="${1:-php}"
  case "${template}" in
    static) printf 'try_files $uri $uri/ =404;' ;;
    laravel) printf 'try_files $uri $uri/ /index.php?$query_string;' ;;
    thinkphp) printf 'try_files $uri $uri/ /index.php?s=$uri&$query_string;' ;;
    *) printf 'try_files $uri $uri/ /index.php?$query_string;' ;;
  esac
}

common_locations_block() {
  cat <<'EOF'

    location ~ /\. {
        deny all;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
EOF
}

acme_challenge_location_block() {
  local root_dir="$1"
  cat <<EOF
    location ^~ /.well-known/acme-challenge/ {
        root ${root_dir};
        default_type text/plain;
        try_files \$uri =404;
    }

EOF
}

render_vhost_http() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local enable_php="${4:-y}"
  local php_version="${5:-84}"
  local force_https="${6:-n}"
  local template="${7:-php}"
  local conf
  conf="$(vhost_conf_file "${domain}")"
  mkdir -p "$(vhost_conf_dir)" "${root_dir}" "${nginx_log_dir}"
  [[ -f "${root_dir}/index.html" ]] || printf 'It works: %s\n' "${domain}" > "${root_dir}/index.html"

  {
    cat <<EOF
server {
    listen ${nginx_http_port:-80};
    server_name $(server_names "${domain}" "${aliases}");
    root ${root_dir};
    index index.php index.html index.htm;
    access_log ${nginx_log_dir}/${domain}.access.log;
    error_log ${nginx_log_dir}/${domain}.error.log;

EOF
    acme_challenge_location_block "${root_dir}"
    if [[ "${force_https}" == "y" ]]; then
      cat <<'EOF'
    location / {
        return 301 https://$host$request_uri;
    }
EOF
    else
      cat <<EOF
    location / {
        $(vhost_try_files_rule "${template}")
    }
EOF
      php_fastcgi_block "${enable_php}" "${php_version}"
      common_locations_block
    fi
    cat <<'EOF'
}
EOF
  } > "${conf}"
}

render_vhost_ssl() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local enable_php="${4:-y}"
  local php_version="${5:-84}"
  local force_https="${6:-y}"
  local template="${7:-php}"
  local conf
  conf="$(vhost_conf_file "${domain}")"
  mkdir -p "$(vhost_conf_dir)" "${root_dir}" "${nginx_log_dir}"

  {
    if [[ "${force_https}" == "y" ]]; then
      cat <<EOF
server {
    listen ${nginx_http_port:-80};
    server_name $(server_names "${domain}" "${aliases}");

$(acme_challenge_location_block "${root_dir}")

    location / {
        return 301 https://\$host\$request_uri;
    }
}

EOF
    else
      render_vhost_http "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version}" "n" "${template}"
      sed -n '1,$p' "${conf}"
      printf '\n'
    fi
    cat <<EOF
server {
    listen ${nginx_https_port:-443} ssl;
    http2 on;
    server_name $(server_names "${domain}" "${aliases}");
    root ${root_dir};
    index index.php index.html index.htm;

    ssl_certificate $(ssl_cert_fullchain_path "${domain}");
    ssl_certificate_key $(ssl_cert_key_path "${domain}");
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    access_log ${nginx_log_dir}/${domain}.ssl.access.log;
    error_log ${nginx_log_dir}/${domain}.ssl.error.log;

    location / {
        $(vhost_try_files_rule "${template}")
    }
EOF
    php_fastcgi_block "${enable_php}" "${php_version}"
    common_locations_block
    cat <<'EOF'
}
EOF
  } > "${conf}"
}
