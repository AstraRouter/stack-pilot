#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
load_options
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/certbot.sh"
source "${ROOT_DIR}/include/vhost_lib.sh"

VERSION="0.1.0"

case "${1:-}" in
  -h|--help)
    echo "Usage: ./vhost.sh"
    echo "Run without parameters and follow the menu."
    exit 0
    ;;
  -v|--version) echo "${VERSION}"; exit 0 ;;
  "") ;;
  *) warn "vhost.sh does not accept operation arguments; opening the interactive menu." ;;
esac

prompt_domain() {
  local domain attempt=0
  while :; do
    domain="$(prompt_input "Enter the domain name" "")"
    if validate_domain "${domain}"; then
      printf '%s' "${domain}"
      return 0
    fi
    warn "Invalid domain name"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "domain name"
  done
}

prompt_aliases() {
  local aliases alias clean=""
  aliases="$(prompt_input "Enter domain aliases separated by spaces, or leave empty" "")"
  for alias in ${aliases}; do
    validate_domain "${alias}" || die "Invalid domain alias: ${alias}"
    clean="${clean:+${clean} }${alias}"
  done
  printf '%s' "${clean}"
}

choose_php_version() {
  local installed configured available version default entries entry
  installed="$(installed_php_versions)"
  configured="$(normalize_php_versions "${php_versions}" 2>/dev/null || true)"
  available="${installed:-${configured}}"
  default="${available%% *}"
  [[ -n "${default}" ]] || default="84"
  entries=()
  for version in ${available:-$(php_supported_versions)}; do
    entries+=("${version}|PHP $(php_version_label "${version}")")
  done
  prompt_select "Select the PHP version for this site" "${default}" "${entries[@]}"
}

choose_site_template() {
  local default="${1:-php}"
  prompt_select "Select the site type and URL routing rule" "${default}" \
    "php|PHP front controller (fallback to index.php)" \
    "laravel|Laravel official Nginx routing (web root is public)" \
    "thinkphp|ThinkPHP URL rewriting (web root is usually public)" \
    "static|Static website (return 404 for missing files)"
}

default_site_root() {
  local domain="$1" template="$2"
  case "${template}" in
    laravel|thinkphp) printf '%s/%s/public' "${wwwroot_dir}" "${domain}" ;;
    *) printf '%s/%s' "${wwwroot_dir}" "${domain}" ;;
  esac
}

site_root_prompt() {
  local template="$1" default="$2" value message attempt=0
  case "${template}" in
    laravel|thinkphp) message="Enter the web root (it must directly contain public/index.php)" ;;
    *) message="Enter the web root" ;;
  esac
  while :; do
    value="$(prompt_input "${message}" "${default}")"
    if validate_path "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "Invalid path: use an absolute path with only letters, digits, dot, dash, underscore, and slash (no spaces or metacharacters)"
    attempt=$((attempt + 1))
    prompt_retry_guard "${attempt}" "web root path"
  done
}

site_php_default() {
  [[ "$1" == "static" ]] && printf 'n' || printf 'y'
}

add_vhost() {
  local domain aliases root_dir enable_php php_version issue_ssl email force_https template
  domain="$(prompt_domain)"
  if vhost_exists "${domain}"; then
    if vhost_has_ssl "${domain}"; then
      warn "${domain} already exists and currently serves HTTPS."
      warn "Continuing replaces its configuration, including the TLS server block."
      warn "To keep the existing certificate, cancel and use 'Regenerate a site's SSL configuration' instead."
    else
      warn "${domain} already exists; continuing replaces its configuration."
    fi
    [[ "$(prompt_yes_no "Replace the existing configuration for ${domain}" "n")" == "y" ]] ||
      die "Cancelled; ${domain} was left unchanged"
  fi
  aliases="$(prompt_aliases)"
  template="$(choose_site_template php)"
  root_dir="$(site_root_prompt "${template}" "$(default_site_root "${domain}" "${template}")")"
  enable_php="$(prompt_yes_no "Enable PHP" "$(site_php_default "${template}")")"
  php_version=""
  [[ "${enable_php}" == "y" ]] && php_version="$(choose_php_version)"
  issue_ssl="$(prompt_yes_no "Request a Let's Encrypt SSL certificate" "y")"
  force_https="n"

  render_vhost_http "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version:-84}" "n" "${template}"
  reload_nginx
  if [[ "${issue_ssl}" == "y" ]]; then
    email="$(prompt_input "Enter the certificate email address" "")"
    [[ -n "${email}" ]] || die "The certificate email address cannot be empty"
    force_https="$(prompt_yes_no "Redirect HTTP to HTTPS" "y")"
    preflight_ssl_certificate "${domain}" "${aliases}" "${root_dir}"
    install_certbot
    # A certificate failure must not discard the working HTTP site: the SSL
    # server block is only rendered once the certificate actually exists.
    if LNMP_SKIP_SSL_PREFLIGHT=1 issue_ssl_certificate "${domain}" "${aliases}" "${root_dir}" "${email}"; then
      render_vhost_ssl "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version:-84}" "${force_https}" "${template}"
    else
      warn "No certificate was issued for ${domain}; the site stays on plain HTTP."
      warn "Retry later with 'Request an SSL certificate for a site'."
    fi
  fi
  reload_nginx
  ok "Site added: ${domain}"
}

delete_vhost() {
  local domain remove_root root_dir
  domain="$(prompt_domain)"
  root_dir="$(vhost_configured_root "${domain}" 2>/dev/null || true)"
  delete_vhost_config "${domain}"
  if [[ -n "${root_dir}" && -d "${root_dir}" ]]; then
    remove_root="$(prompt_yes_no "Delete the website directory ${root_dir}" "n")"
    if [[ "${remove_root}" == "y" ]]; then
      if vhost_docroot_removable "${root_dir}"; then
        rm -rf -- "${root_dir}"
      else
        warn "Refusing to remove ${root_dir}: it is not a sub-directory of ${wwwroot_dir}. Remove it manually if you are sure."
      fi
    fi
  fi
  reload_nginx
  ok "Site deleted: ${domain}"
}

list_sites() {
  echo
  echo "Virtual hosts:"
  list_vhosts || true
}

issue_ssl_for_existing() {
  local domain aliases root_dir enable_php php_version email force_https template
  domain="$(prompt_domain)"
  [[ -f "$(vhost_conf_file "${domain}")" ]] || die "Site configuration does not exist: ${domain}"
  aliases="$(prompt_aliases)"
  root_dir="$(vhost_configured_root "${domain}" 2>/dev/null || true)"
  template="$(choose_site_template php)"
  root_dir="$(site_root_prompt "${template}" "${root_dir:-$(default_site_root "${domain}" "${template}")}")"
  enable_php="$(prompt_yes_no "Enable PHP" "$(site_php_default "${template}")")"
  php_version=""
  [[ "${enable_php}" == "y" ]] && php_version="$(choose_php_version)"
  email="$(prompt_input "Enter the certificate email address" "")"
  [[ -n "${email}" ]] || die "The certificate email address cannot be empty"
  force_https="$(prompt_yes_no "Redirect HTTP to HTTPS" "y")"
  render_vhost_http "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version:-84}" "n" "${template}"
  reload_nginx
  preflight_ssl_certificate "${domain}" "${aliases}" "${root_dir}"
  install_certbot
  if ! LNMP_SKIP_SSL_PREFLIGHT=1 issue_ssl_certificate "${domain}" "${aliases}" "${root_dir}" "${email}"; then
    reload_nginx
    die "No certificate was issued for ${domain}; the site stays on plain HTTP"
  fi
  render_vhost_ssl "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version:-84}" "${force_https}" "${template}"
  reload_nginx
  ok "Certificate configured: ${domain}"
}

renew_certs() {
  install_certbot
  renew_all_certificates
  ok "Certificate renewal check completed"
}

show_cert_status() {
  list_certificate_status
}

switch_php_for_existing() {
  local domain php_version
  domain="$(prompt_domain)"
  php_version="$(choose_php_version)"
  switch_vhost_php_version "${domain}" "${php_version}"
  reload_nginx
  ok "Site ${domain} switched to PHP ${php_version}"
}

regenerate_ssl_for_existing() {
  local domain aliases root_dir enable_php php_version template force_https
  domain="$(prompt_domain)"
  [[ -f "$(vhost_conf_file "${domain}")" ]] || die "Site configuration does not exist: ${domain}"
  aliases="$(prompt_aliases)"
  root_dir="$(vhost_configured_root "${domain}" 2>/dev/null || true)"
  template="$(choose_site_template php)"
  root_dir="$(site_root_prompt "${template}" "${root_dir:-$(default_site_root "${domain}" "${template}")}")"
  enable_php="$(prompt_yes_no "Enable PHP" "$(site_php_default "${template}")")"
  php_version=""
  [[ "${enable_php}" == "y" ]] && php_version="$(choose_php_version)"
  force_https="$(prompt_yes_no "Redirect HTTP to HTTPS" "y")"
  render_vhost_ssl "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version:-84}" "${force_https}" "${template}"
  reload_nginx
  ok "SSL configuration regenerated for ${domain}"
}

while :; do
  print_header
  choice="$(prompt_select "Select an action" "1" \
    "1|Add a virtual host" \
    "2|Delete a virtual host" \
    "3|List virtual hosts" \
    "4|Request an SSL certificate for a site" \
    "5|Renew all SSL certificates" \
    "6|Show certificate status" \
    "7|Switch a site's PHP version" \
    "8|Regenerate a site's SSL configuration" \
    "9|Exit")"
  case "${choice}" in
    1) run_menu_action "Adding the virtual host" add_vhost ;;
    2) run_menu_action "Deleting the virtual host" delete_vhost ;;
    3) run_menu_action "Listing virtual hosts" list_sites ;;
    4) run_menu_action "Requesting the certificate" issue_ssl_for_existing ;;
    5) run_menu_action "Renewing certificates" renew_certs ;;
    6) run_menu_action "Reading certificate status" show_cert_status ;;
    7) run_menu_action "Switching the PHP version" switch_php_for_existing ;;
    8) run_menu_action "Regenerating the SSL configuration" regenerate_ssl_for_existing ;;
    9) exit 0 ;;
  esac
  pause_for_menu
done
