#!/usr/bin/env bash

# A PECL build failure is only a warning in the middle of thousands of lines of
# compiler output, so it is also recorded here and reported again at the end of
# the run and in install.txt. Otherwise the first sign of a missing extension is
# a "class not found" error in production.
LNMP_PECL_FAILURES="${LNMP_PECL_FAILURES:-}"

record_pecl_failure() {
  LNMP_PECL_FAILURES="${LNMP_PECL_FAILURES:+${LNMP_PECL_FAILURES} }php$(php_version_label "$1"):$2"
}

php_pecl_failure_summary() {
  [[ -n "${LNMP_PECL_FAILURES:-}" ]] || return 1
  printf '%s' "${LNMP_PECL_FAILURES}"
}

install_php_pecl_extensions() {
  local short="$1"
  local extensions="$2"
  local prefix ext pecl_bin
  local failed=()
  prefix="$(php_install_dir_for_version "${short}")"
  pecl_bin="${prefix}/bin/pecl"
  [[ -x "${pecl_bin}" ]] || { warn "PHP ${short}: pecl was not found at ${pecl_bin}"; return 0; }
  for ext in ${extensions}; do
    install_php_pecl_extension "${short}" "${ext}" || { failed+=("${ext}"); record_pecl_failure "${short}" "${ext}"; }
  done
  if ((${#failed[@]} > 0)); then
    warn "PHP ${short}: these PECL extensions were skipped after errors and can be retried with ./addons.sh: ${failed[*]}"
  fi
  return 0
}

install_php_pecl_extension() {
  local short="$1"
  local ext="$2"
  local prefix pecl_bin ini_dir package ini_name
  if ! php_pecl_extension_supported "${short}" "${ext}"; then
    warn "PHP ${short}: skipping incompatible or manual-only extension ${ext}"
    return 0
  fi
  prefix="$(php_install_dir_for_version "${short}")"
  pecl_bin="${prefix}/bin/pecl"
  ini_dir="${prefix}/etc/php.d"
  mkdir -p "${ini_dir}"
  package="$(php_pecl_package "${short}" "${ext}")"
  ini_name="${ext}.ini"
  case "${ext}" in
    memcache) package="$(php_pecl_package "${short}" "${ext}")" ;;
    *) ;;
  esac
  if "${prefix}/bin/php" -m 2>/dev/null | grep -qi "^${ext}$"; then
    ok "PHP ${short}: extension ${ext} is already installed"
    return 0
  fi
  printf "\n" | "${pecl_bin}" install "${package}" || { warn "PHP ${short}: extension ${ext} failed to install"; return 1; }
  if [[ "${ext}" == "xdebug" ]]; then
    printf 'zend_extension=%s.so\n' "${ext}" > "${ini_dir}/${ini_name}"
  else
    printf 'extension=%s.so\n' "${ext}" > "${ini_dir}/${ini_name}"
  fi
  systemctl_reload_or_restart "$(php_service_name "${short}")" || true
}

php_pecl_package() {
  local short="${1//./}"
  local ext="$2"
  case "${ext}" in
    redis)
      case "${short}" in
        54|55) printf 'redis-4.3.0' ;;
        56|70|71) printf 'redis-5.3.7' ;;
        72|73|74) printf 'redis-6.0.2' ;;
        *) printf 'redis' ;;
      esac
      ;;
    memcached)
      case "${short}" in
        54|55|56|70) printf 'memcached-2.2.0' ;;
        71|72|73|74) printf 'memcached-3.2.0' ;;
        *) printf 'memcached' ;;
      esac
      ;;
    memcache)
      case "${short}" in
        54|55|56|70|71|72|73) printf 'memcache-4.0.5.2' ;;
        *) printf 'memcache' ;;
      esac
      ;;
    xdebug)
      case "${short}" in
        54|55) printf 'xdebug-2.4.1' ;;
        56) printf 'xdebug-2.5.5' ;;
        70|71|72|73|74) printf 'xdebug-3.1.6' ;;
        80|81|82) printf 'xdebug-3.3.2' ;;
        *) printf 'xdebug' ;;
      esac
      ;;
    swoole)
      case "${short}" in
        54|55|56) printf 'swoole-2.0.11' ;;
        70|71|72|73|74) printf 'swoole-4.8.13' ;;
        80|81|82) printf 'swoole-5.1.5' ;;
        *) printf 'swoole' ;;
      esac
      ;;
    imagick)
      case "${short}" in
        54|55|56|70|71|72|73|74) printf 'imagick-3.4.4' ;;
        *) printf 'imagick' ;;
      esac
      ;;
    mongodb)
      case "${short}" in
        54|55|56) printf 'mongodb-1.7.5' ;;
        70|71|72|73|74) printf 'mongodb-1.19.1' ;;
        *) printf 'mongodb' ;;
      esac
      ;;
    *)
      printf '%s' "${ext}"
      ;;
  esac
}
