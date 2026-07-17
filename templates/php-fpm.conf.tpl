[global]
pid = {{pid_dir}}/php{{php_version}}-fpm.pid
error_log = {{php_log_dir}}/php{{php_version}}-fpm.log
include={{php_install_dir}}/etc/php-fpm.d/*.conf
