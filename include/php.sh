#!/usr/bin/env bash

install_php_versions() {
  local versions="$1"
  local version default_version
  for version in ${versions}; do
    run_step_once "php:${version}" install_php_version "${version}"
  done
  default_version="${versions%% *}"
  [[ -n "${default_version}" ]] && switch_cli_php_version "${default_version}"
}

install_php_version() {
  local short="${1//./}"
  local full url prefix port service build_dir archive configure_flags extension_flags
  full="$(php_source_version "${short}")" || die "Unsupported PHP version: ${short}"
  url="$(php_source_url "${short}")"
  prefix="$(php_install_dir_for_version "${short}")"
  port="$(php_fpm_port "${short}")"
  service="$(php_service_name "${short}")"

  if [[ -x "${prefix}/sbin/php-fpm" ]]; then
    if [[ "${LNMP_FORCE_REINSTALL:-0}" != "1" ]]; then
      warn "PHP $(php_version_label "${short}") is already installed: ${prefix}"
      return 0
    fi
    warn "PHP $(php_version_label "${short}") will be rebuilt because an explicit upgrade was requested"
  fi

  download_src "${url}" "${url##*/}" "$(php_source_sha256 "${short}" 2>/dev/null || true)"
  archive="${LNMP_SRC_DIR}/${url##*/}"
  build_dir="$(make_build_dir)"
  extract_archive "${archive}" "${build_dir}"

  # user and group land in ./configure --with-fpm-user= and later in
  # php-fpm.d/www.conf; options.conf can set them without a wizard prompt.
  validate_unix_username "${user}" || die "Invalid service user: ${user}"
  validate_unix_username "${group}" || die "Invalid service group: ${group}"

  pushd "${build_dir}/php-${full}" >/dev/null || die "Could not enter the build directory"
  configure_flags=(
    "--prefix=${prefix}"
    "--with-config-file-path=${prefix}/etc"
    "--with-config-file-scan-dir=${prefix}/etc/php.d"
    "--enable-fpm"
    "--with-fpm-user=${user}"
    "--with-fpm-group=${group}"
    "--with-zlib"
    "--enable-mysqlnd"
    "--with-pear"
  )
  while IFS= read -r extension_flags; do
    [[ -n "${extension_flags}" ]] && configure_flags+=("${extension_flags}")
  done < <(php_configure_flags_for_extensions "${short}" "${php_extensions}")

  ./configure "${configure_flags[@]}"
  make -j"$(build_parallelism)"
  make install
  [[ -x "${prefix}/bin/phpize" ]] || die "phpize was not found after installing PHP ${short}"
  [[ -x "${prefix}/bin/php-config" ]] || die "php-config was not found after installing PHP ${short}"
  mkdir -p "${prefix}/etc/php.d"
  cp php.ini-production "${prefix}/etc/php.ini"
  popd >/dev/null || die "Could not leave the build directory"
  rm -rf "${build_dir}"

  write_php_timezone_ini "${short}"
  write_php_fpm_conf "${short}" "${prefix}" "${port}"
  write_php_service "${short}" "${prefix}"
  systemctl_reload_or_restart "${service}"
  install_php_pecl_extensions "${short}" "${php_pecl_extensions:-}"
}

# The wizard's time-zone answer used to set TZ for the installer process only.
# PHP falls back to UTC whenever date.timezone is unset, so every site would
# report times in a zone the operator never chose. The scan directory is read in
# lexical order, so this file is applied before 99-security.ini.
write_php_timezone_ini() {
  local short="$1" prefix
  local zone="${timezone:-}"
  [[ -n "${zone}" ]] || return 0
  validate_timezone "${zone}" || die "Invalid timezone: ${zone}"
  prefix="$(php_install_dir_for_version "${short}")"
  mkdir -p "${prefix}/etc/php.d"
  printf 'date.timezone = %s\n' "${zone}" > "${prefix}/etc/php.d/10-timezone.ini"
}

# Every value below is interpolated unquoted into php-fpm.d/www.conf, and
# options.conf can set them without passing through a wizard prompt. A wrong
# process-manager name or size unit stops php-fpm from starting at all, and a
# value carrying a newline would append further php_admin_value directives.
assert_php_fpm_tunables() {
  validate_php_pm_mode "${php_pm:-}" ||
    die "Invalid php_pm: ${php_pm:-} (expected static, dynamic, or ondemand)"
  local name value
  for name in php_pm_max_children php_pm_start_servers php_pm_min_spare_servers php_pm_max_spare_servers; do
    value="${!name:-}"
    validate_positive_integer "${value}" 100000 ||
      die "Invalid ${name}: ${value} (expected an integer from 1 through 100000)"
  done
  for name in php_memory_limit php_upload_max_filesize php_post_max_size; do
    value="${!name:-}"
    validate_size_value "${value}" ||
      die "Invalid ${name}: ${value} (expected a size such as 256M)"
  done
  validate_positive_integer "${php_max_execution_time:-}" 86400 ||
    die "Invalid php_max_execution_time: ${php_max_execution_time:-} (expected seconds from 1 through 86400)"
  # dynamic requires start_servers to sit between the spare-server bounds, and
  # php-fpm refuses to start otherwise.
  if [[ "${php_pm}" == "dynamic" ]]; then
    if ((10#${php_pm_min_spare_servers} > 10#${php_pm_start_servers})) ||
       ((10#${php_pm_start_servers} > 10#${php_pm_max_spare_servers})); then
      die "php_pm=dynamic requires php_pm_min_spare_servers <= php_pm_start_servers <= php_pm_max_spare_servers"
    fi
    ((10#${php_pm_max_spare_servers} <= 10#${php_pm_max_children})) ||
      die "php_pm_max_spare_servers must not exceed php_pm_max_children"
  fi
}

write_php_fpm_conf() {
  local short="$1"
  local prefix="$2"
  local port="$3"
  validate_unix_username "${user}" || die "Invalid service user: ${user}"
  validate_unix_username "${group}" || die "Invalid service group: ${group}"
  assert_php_fpm_tunables
  mkdir -p "${prefix}/etc/php-fpm.d" "${php_log_dir}" "${pid_dir}"
  cat > "${prefix}/etc/php-fpm.conf" <<EOF
[global]
pid = ${pid_dir}/php${short}-fpm.pid
error_log = ${php_log_dir}/php${short}-fpm.log
include=${prefix}/etc/php-fpm.d/*.conf
EOF
  cat > "${prefix}/etc/php-fpm.d/www.conf" <<EOF
[www]
user = ${user}
group = ${group}
listen = 127.0.0.1:${port}
listen.allowed_clients = 127.0.0.1
pm = ${php_pm}
pm.max_children = ${php_pm_max_children}
pm.start_servers = ${php_pm_start_servers}
pm.min_spare_servers = ${php_pm_min_spare_servers}
pm.max_spare_servers = ${php_pm_max_spare_servers}
request_terminate_timeout = 300
php_admin_value[memory_limit] = ${php_memory_limit}
php_admin_value[upload_max_filesize] = ${php_upload_max_filesize}
php_admin_value[post_max_size] = ${php_post_max_size}
php_admin_value[max_execution_time] = ${php_max_execution_time}
EOF
}

write_php_service() {
  local short="$1"
  local prefix="$2"
  local service
  service="$(php_service_name "${short}")"
  cat > "/etc/systemd/system/${service}.service" <<EOF
[Unit]
Description=PHP ${short} FastCGI Process Manager
After=network.target

[Service]
Type=simple
PIDFile=${pid_dir}/php${short}-fpm.pid
ExecStart=${prefix}/sbin/php-fpm --nodaemonize --fpm-config ${prefix}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
}

installed_php_versions() {
  local version dir found=""
  for version in $(php_supported_versions); do
    dir="$(php_install_dir_for_version "${version}")"
    [[ -x "${dir}/sbin/php-fpm" ]] && found="${found:+${found} }${version}"
  done
  printf '%s' "${found}"
}
