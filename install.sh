#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_versions
load_options
source "${ROOT_DIR}/include/nginx.sh"
source "${ROOT_DIR}/include/php_extensions.sh"
source "${ROOT_DIR}/include/php.sh"
source "${ROOT_DIR}/include/mysql.sh"
source "${ROOT_DIR}/include/mariadb.sh"
source "${ROOT_DIR}/include/redis.sh"
source "${ROOT_DIR}/include/memcached.sh"
source "${ROOT_DIR}/include/certbot.sh"
source "${ROOT_DIR}/include/composer.sh"
source "${ROOT_DIR}/include/firewall.sh"
source "${ROOT_DIR}/include/fail2ban.sh"
source "${ROOT_DIR}/include/logrotate.sh"
source "${ROOT_DIR}/include/security.sh"
source "${ROOT_DIR}/include/install/wizard.sh"
source "${ROOT_DIR}/include/install/options.sh"
source "${ROOT_DIR}/include/install/status.sh"
source "${ROOT_DIR}/include/install/runtime.sh"
source "${ROOT_DIR}/include/install/unattended.sh"
source "${ROOT_DIR}/include/install/main.sh"

VERSION="0.1.0"

run_install_entrypoint "$@"
