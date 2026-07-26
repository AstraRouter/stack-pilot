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

# $uri and $query_string are Nginx variables resolved by Nginx at request time;
# single quotes keep the shell from expanding them.
# shellcheck disable=SC2016
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

render_vhost_http_body() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local enable_php="${4:-y}"
  local php_version="${5:-84}"
  local force_https="${6:-n}"
  local template="${7:-php}"
  cat <<EOF
server {
    listen ${nginx_http_port:-80};
    server_name $(server_names "${domain}" "${aliases}");
    root ${root_dir};
    index index.php index.html index.htm;
    access_log ${nginx_log_dir}/${domain}.access.log;
    error_log ${nginx_log_dir}/${domain}.error.log;$(nginx_security_header_lines http)

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
        $(vhost_try_files_rule "${template}")$(nginx_rate_limit_directives)
    }
EOF
    php_fastcgi_block "${enable_php}" "${php_version}"
    common_locations_block
  fi
  cat <<'EOF'
}
EOF
}

# The document root of a Laravel or ThinkPHP site is <site>/public, while the
# directories the framework must write — storage, bootstrap/cache, runtime — are
# siblings of it directly under <site>. Handing over only the document root
# therefore leaves the application unable to write, so ownership is applied to
# the site directory: the first component below the web root.
vhost_ownership_root() {
  local root_dir="${1%/}" web_root="${wwwroot_dir%/}" remainder
  if [[ -z "${web_root}" || "${root_dir}" != "${web_root}/"* ]]; then
    printf '%s' "${root_dir}"
    return 0
  fi
  remainder="${root_dir#"${web_root}/"}"
  printf '%s/%s' "${web_root}" "${remainder%%/*}"
}

grant_vhost_ownership() {
  local path="$1" owner="$2" owner_group="$3"
  if ! id "${owner}" >/dev/null 2>&1; then
    warn "Service user ${owner} does not exist; ${path} stays owned by the current user"
    return 0
  fi
  # Without this, PHP-FPM cannot write uploads, Laravel storage, or ThinkPHP
  # runtime under the new site.
  chown -R "${owner}:${owner_group}" "${path}" 2>/dev/null ||
    warn "Could not set ownership of ${path} to ${owner}:${owner_group}"
}

# Create a web root and hand it to the service account. Ownership is only
# applied to a tree this call created: an existing site may hold a deployed
# application whose ownership must not be rewritten.
prepare_vhost_docroot() {
  local root_dir="$1" domain="$2"
  local owner="${user:-www}" owner_group="${group:-www}"
  local ownership_root
  mkdir -p "${nginx_log_dir}"
  ownership_root="$(vhost_ownership_root "${root_dir}")"
  if [[ -d "${ownership_root}" ]]; then
    [[ -d "${root_dir}" ]] && return 0
    # The site exists but this document root does not, so only the new
    # sub-directory is handed over.
    mkdir -p "${root_dir}"
    printf 'It works: %s\n' "${domain}" > "${root_dir}/index.html"
    grant_vhost_ownership "${root_dir}" "${owner}" "${owner_group}"
    return 0
  fi
  mkdir -p "${root_dir}"
  printf 'It works: %s\n' "${domain}" > "${root_dir}/index.html"
  grant_vhost_ownership "${ownership_root}" "${owner}" "${owner_group}"
}

render_vhost_http() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local enable_php="${4:-y}"
  local php_version="${5:-84}"
  local force_https="${6:-n}"
  local template="${7:-php}"
  local conf candidate
  # Checked once here rather than inside the heredocs below, where a die would
  # only end its own $( ) subshell and leave a half-written directive.
  assert_nginx_policy_options
  conf="$(vhost_conf_file "${domain}")"
  mkdir -p "$(vhost_conf_dir)"
  prepare_vhost_docroot "${root_dir}" "${domain}"
  candidate="$(mktemp)"
  render_vhost_http_body "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version}" "${force_https}" "${template}" > "${candidate}"
  install_vhost_config "${conf}" "${candidate}"
}

render_vhost_ssl() {
  local domain="$1"
  local aliases="${2:-}"
  local root_dir="$3"
  local enable_php="${4:-y}"
  local php_version="${5:-84}"
  local force_https="${6:-y}"
  local template="${7:-php}"
  local conf candidate
  # Checked once here rather than inside the heredocs below, where a die would
  # only end its own $( ) subshell and leave a half-written directive.
  assert_nginx_policy_options
  conf="$(vhost_conf_file "${domain}")"
  mkdir -p "$(vhost_conf_dir)"
  prepare_vhost_docroot "${root_dir}" "${domain}"
  candidate="$(mktemp)"
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
      render_vhost_http_body "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version}" "n" "${template}"
      printf '\n'
    fi
    cat <<EOF
server {
    listen ${nginx_https_port:-443} ssl;$(nginx_http3_listen_line)
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
    error_log ${nginx_log_dir}/${domain}.ssl.error.log;$(nginx_security_header_lines https)$(nginx_http3_advertise_header)

    location / {
        $(vhost_try_files_rule "${template}")$(nginx_rate_limit_directives)
    }
EOF
    php_fastcgi_block "${enable_php}" "${php_version}"
    common_locations_block
    cat <<'EOF'
}
EOF
  } > "${candidate}"
  install_vhost_config "${conf}" "${candidate}"
}
