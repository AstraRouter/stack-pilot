#!/usr/bin/env bash

save_runtime_options() {
  local file="${LNMP_OPTIONS_FILE:-${ROOT_DIR}/options.conf}"
  local key
  local option_keys=(
    timezone user group services_base_dir data_base_dir runtime_base_dir pid_dir sock_dir logs_dir
    nginx_ver mysql_ver mariadb_ver redis_ver
    nginx_install_dir php_install_base mysql_install_dir mariadb_install_dir redis_install_dir
    mysql_data_dir mariadb_data_dir redis_data_dir wwwroot_dir backup_dir
    nginx_log_dir php_log_dir mysql_log_dir mariadb_log_dir redis_log_dir
    mysql_sock mariadb_sock mysql_pid mariadb_pid nginx_pid
    mysql_password mariadb_password redis_password php_versions db_engine install_redis
    install_components install_memcached install_composer
    nginx_http_port nginx_https_port mysql_port mariadb_port redis_port redis_bind redis_appendonly
    nginx_worker_connections nginx_keepalive_timeout nginx_client_max_body_size
    nginx_security_headers nginx_hsts_max_age nginx_http3
    nginx_rate_limit nginx_rate_limit_rps nginx_rate_limit_burst nginx_conn_limit
    backup_keep_days upgrade_keep_failed
    manage_logrotate logrotate_interval logrotate_keep
    fail2ban_bantime fail2ban_findtime fail2ban_maxretry
    memcached_install_dir composer_install_dir memcached_data_dir memcached_log_dir
    memcached_port memcached_bind memcached_memory
    php_pm php_pm_max_children php_pm_start_servers php_pm_min_spare_servers php_pm_max_spare_servers
    php_memory_limit php_upload_max_filesize php_post_max_size php_max_execution_time
    php_profile php_extensions php_pecl_extensions
    customize_service_ports manage_firewall open_database_port open_redis_port open_memcached_port
    php_security_hardening php_disable_functions
  )
  # An options.conf written by an older release does not define keys added
  # since. Treating that as an unbound variable would abort the run at its very
  # last step, after everything was already installed; an empty value instead
  # falls back to each option's own default at the point of use.
  for key in "${option_keys[@]}"; do
    set_config_value "${file}" "${key}" "${!key-}"
  done
}
