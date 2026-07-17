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
  local domain
  while :; do
    domain="$(prompt_input "Enter the domain name" "")"
    if validate_domain "${domain}"; then
      printf '%s' "${domain}"
      return 0
    fi
    warn "Invalid domain name"
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
  for version in ${available:-54 55 56 70 71 72 73 74 80 81 82 83 84 85}; do
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
  local template="$1" default="$2"
  case "${template}" in
    laravel|thinkphp) prompt_input "Enter the web root (it must directly contain public/index.php)" "${default}" ;;
    *) prompt_input "Enter the web root" "${default}" ;;
  esac
}

site_php_default() {
  [[ "$1" == "static" ]] && printf 'n' || printf 'y'
}

add_vhost() {
  local domain aliases root_dir enable_php php_version issue_ssl email force_https template
  domain="$(prompt_domain)"
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
    LNMP_SKIP_SSL_PREFLIGHT=1 issue_ssl_certificate "${domain}" "${aliases}" "${root_dir}" "${email}"
    render_vhost_ssl "${domain}" "${aliases}" "${root_dir}" "${enable_php}" "${php_version:-84}" "${force_https}" "${template}"
  fi
  reload_nginx
  ok "Site added: ${domain}"
}

delete_vhost() {
  local domain remove_root root_dir
  domain="$(prompt_domain)"
  root_dir="$(awk '/^[[:space:]]*root[[:space:]]+/ { gsub(/;/, "", $2); print $2; exit }' "$(vhost_conf_file "${domain}")" 2>/dev/null || true)"
  delete_vhost_config "${domain}"
  if [[ -n "${root_dir}" && -d "${root_dir}" ]]; then
    remove_root="$(prompt_yes_no "Delete the website directory ${root_dir}" "n")"
    [[ "${remove_root}" == "y" ]] && rm -rf "${root_dir}"
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
  root_dir="$(awk '/^[[:space:]]*root[[:space:]]+/ { gsub(/;/, "", $2); print $2; exit }' "$(vhost_conf_file "${domain}")")"
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
  LNMP_SKIP_SSL_PREFLIGHT=1 issue_ssl_certificate "${domain}" "${aliases}" "${root_dir}" "${email}"
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
  root_dir="$(awk '/^[[:space:]]*root[[:space:]]+/ { gsub(/;/, "", $2); print $2; exit }' "$(vhost_conf_file "${domain}")")"
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
    1) add_vhost ;;
    2) delete_vhost ;;
    3) list_sites ;;
    4) issue_ssl_for_existing ;;
    5) renew_certs ;;
    6) show_cert_status ;;
    7) switch_php_for_existing ;;
    8) regenerate_ssl_for_existing ;;
    9) exit 0 ;;
  esac
  echo
  read -r -p "Press Enter to return to the menu..." _
done
