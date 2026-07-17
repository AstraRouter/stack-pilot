user {{user}} {{group}};
worker_processes auto;
error_log {{nginx_log_dir}}/error.log warn;
pid {{nginx_pid}};

events {
    worker_connections {{nginx_worker_connections}};
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    server_tokens off;
    access_log {{nginx_log_dir}}/access.log main;
    include {{nginx_install_dir}}/conf/vhost/*.conf;
}
