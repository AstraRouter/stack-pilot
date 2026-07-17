server {
    listen {{nginx_http_port}};
    server_name {{server_name}};
    root {{root_dir}};
    index index.php index.html index.htm;
}
