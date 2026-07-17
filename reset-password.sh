#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/include/common.sh"
load_options
source "${ROOT_DIR}/include/mysql.sh"
source "${ROOT_DIR}/include/mariadb.sh"
source "${ROOT_DIR}/include/redis.sh"
source "${ROOT_DIR}/include/password_reset.sh"

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage:
  ./reset-password.sh
  ./reset-password.sh mysql [new_password]
  ./reset-password.sh mariadb [new_password]
  ./reset-password.sh redis [new_password]

Database password left empty in the interactive prompt will be randomly generated.
Redis password left empty in the interactive prompt disables Redis authentication.
EOF
    exit 0
    ;;
esac

prompt_secret() {
  local message="$1"
  local value
  read -r -s -p "? ${message}: " value
  echo >&2
  printf '%s' "${value}"
}

confirm_action() {
  local message="$1"
  local answer
  answer="$(prompt_yes_no "${message}" "n")"
  [[ "${answer}" == "y" ]]
}

save_password_option() {
  local key="$1"
  local value="$2"
  set_config_value "${LNMP_OPTIONS_FILE:-${ROOT_DIR}/options.conf}" "${key}" "${value}"
}

reset_mysql_password_flow() {
  local password="${1:-}"
  require_root
  [[ -n "${password}" ]] || password="$(prompt_secret "Enter the new MySQL root password, or leave empty to generate one")"
  [[ -n "${password}" ]] || password="$(random_password 20)"
  validate_password_or_random "${password}" 6 || die "The MySQL password must be at least 6 characters and must not contain single quotes or backslashes"
  confirm_action "Reset the MySQL root password" || die "Cancelled"
  reset_database_root_password mysql "${password}"
  mysql_password="${password}"
  save_password_option mysql_password "${password}"
  ok "The MySQL root password was reset and saved to options.conf"
  echo "  MySQL: ${password}"
}

reset_mariadb_password_flow() {
  local password="${1:-}"
  require_root
  [[ -n "${password}" ]] || password="$(prompt_secret "Enter the new MariaDB root password, or leave empty to generate one")"
  [[ -n "${password}" ]] || password="$(random_password 20)"
  validate_password_or_random "${password}" 6 || die "The MariaDB password must be at least 6 characters and must not contain single quotes or backslashes"
  confirm_action "Reset the MariaDB root password" || die "Cancelled"
  reset_database_root_password mariadb "${password}"
  mariadb_password="${password}"
  save_password_option mariadb_password "${password}"
  ok "The MariaDB root password was reset and saved to options.conf"
  echo "  MariaDB: ${password}"
}

reset_redis_password_flow() {
  local password="${1-__prompt__}"
  require_root
  if [[ "${password}" == "__prompt__" ]]; then
    password="$(prompt_secret "Enter the new Redis password, or leave empty to disable authentication")"
  fi
  confirm_action "Update the Redis password configuration" || die "Cancelled"
  reset_redis_password "${password}"
  save_password_option redis_password "${password}"
  if [[ -n "${password}" ]]; then
    ok "The Redis password was updated and saved to options.conf"
    echo "  Redis: ${password}"
  else
    ok "The Redis password was cleared and saved to options.conf"
  fi
}

run_interactive() {
  local choice
  while :; do
    print_header
    choice="$(prompt_select "Select a password to reset" "mysql" \
      "mysql|MySQL root password" \
      "mariadb|MariaDB root password" \
      "redis|Redis password" \
      "exit|Exit")"
    case "${choice}" in
      mysql) reset_mysql_password_flow ;;
      mariadb) reset_mariadb_password_flow ;;
      redis) reset_redis_password_flow ;;
      exit) exit 0 ;;
    esac
    echo
    read -r -p "Press Enter to return to the menu..." _
  done
}

case "${1:-}" in
  mysql) reset_mysql_password_flow "${2:-}" ;;
  mariadb) reset_mariadb_password_flow "${2:-}" ;;
  redis)
    if (($# >= 2)); then
      reset_redis_password_flow "$2"
    else
      reset_redis_password_flow
    fi
    ;;
  "") run_interactive ;;
  *) die "Unknown operation: $1. Run ./reset-password.sh --help for usage." ;;
esac
