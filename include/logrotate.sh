#!/usr/bin/env bash

# Nothing rotated the logs this installer creates, so nginx access logs, PHP-FPM
# logs, and database error logs grew without bound until they filled the
# partition holding /data and took the whole stack down with them.

logrotate_config_path() {
  printf '%s' "${LNMP_LOGROTATE_FILE:-/etc/logrotate.d/stack-pilot}"
}

logrotate_interval_value() {
  case "${logrotate_interval:-daily}" in
    daily|weekly|monthly) printf '%s' "${logrotate_interval:-daily}" ;;
    *) die "Invalid logrotate_interval: ${logrotate_interval} (expected daily, weekly, or monthly)" ;;
  esac
}

logrotate_keep_count() {
  local value="${logrotate_keep:-14}"
  validate_positive_integer "${value}" 3650 ||
    die "Invalid logrotate_keep: ${value} (expected an integer from 1 through 3650)"
  printf '%s' "$((10#${value}))"
}

# Checked before rendering starts. The helpers below run inside $( ) within
# heredocs, where a die only ends the substitution subshell and would leave a
# config file with a blank directive that logrotate then refuses -- taking every
# other logrotate config on the host down with it.
assert_logrotate_options() {
  logrotate_interval_value >/dev/null
  logrotate_keep_count >/dev/null
}

logrotate_common_options() {
  cat <<EOF
    $(logrotate_interval_value)
    rotate $(logrotate_keep_count)
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
EOF
}

# Nginx and PHP-FPM both reopen their log files on SIGUSR1, so the file can be
# renamed and the process told to start a new one with no lost lines.
# Paths carry their own defaults: an options.conf written by an earlier release
# does not define every key, and an unbound variable here would abort a run that
# has already installed everything.
logrotate_nginx_block() {
  local log_dir="${nginx_log_dir:-${logs_dir:-/data/logs}/nginx}"
  local pid_file="${nginx_pid:-${pid_dir:-/data/pid}/nginx.pid}"
  cat <<EOF
${log_dir}/*.log {
$(logrotate_common_options)
    postrotate
        [ -f ${pid_file} ] && kill -USR1 \$(cat ${pid_file}) 2>/dev/null || true
    endscript
}

EOF
}

logrotate_php_block() {
  local log_dir="${php_log_dir:-${logs_dir:-/data/logs}/php}"
  local run_dir="${pid_dir:-/data/pid}"
  cat <<EOF
${log_dir}/*.log {
$(logrotate_common_options)
    postrotate
        for pidfile in ${run_dir}/php*-fpm.pid; do
            [ -f "\$pidfile" ] && kill -USR1 \$(cat "\$pidfile") 2>/dev/null || true
        done
    endscript
}

EOF
}

# MySQL, MariaDB, Redis, and Memcached hold their log file open and only reopen
# it on an authenticated FLUSH LOGS or a restart, so the file is truncated in
# place instead. A few lines written during the copy can be lost, which is a
# better trade than an unbounded file or a service restart.
logrotate_copytruncate_block() {
  local pattern="$1"
  cat <<EOF
${pattern} {
$(logrotate_common_options)
    copytruncate
}

EOF
}

render_logrotate_config() {
  local base="${logs_dir:-/data/logs}"
  assert_logrotate_options
  has_component nginx && logrotate_nginx_block
  has_component php && logrotate_php_block
  [[ "${db_engine:-none}" == "mysql" ]] && logrotate_copytruncate_block "${mysql_log_dir:-${base}/mysql}/*.log"
  [[ "${db_engine:-none}" == "mariadb" ]] && logrotate_copytruncate_block "${mariadb_log_dir:-${base}/mariadb}/*.log"
  has_component redis && logrotate_copytruncate_block "${redis_log_dir:-${base}/redis}/*.log"
  has_component memcached && logrotate_copytruncate_block "${memcached_log_dir:-${base}/memcached}/*.log"
  return 0
}

configure_logrotate() {
  local target rendered
  [[ "${manage_logrotate:-y}" == "y" ]] || return 0
  if ! command_exists logrotate; then
    warn "logrotate is not installed, so log rotation was not configured; logs under ${logs_dir} will grow without bound"
    return 0
  fi
  target="$(logrotate_config_path)"
  rendered="$(render_logrotate_config)"
  if [[ -z "${rendered}" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "${target}")"
  printf '%s' "${rendered}" > "${target}"
  chmod 644 "${target}"
  # A malformed file would stop logrotate from processing every other config on
  # the host, not just this one.
  if ! logrotate -d "${target}" >/dev/null 2>&1; then
    rm -f "${target}"
    warn "The generated logrotate configuration was rejected and has been removed; configure rotation manually"
    return 1
  fi
  ok "Log rotation configured: ${target}"
}
