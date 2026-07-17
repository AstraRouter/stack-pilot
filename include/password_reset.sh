#!/usr/bin/env bash

_PASSWORD_RESET_MODULE_DIR="${LNMP_ROOT_DIR}/include/password_reset"
for _password_reset_module in database_paths database redis; do
  # shellcheck source=/dev/null
  source "${_PASSWORD_RESET_MODULE_DIR}/${_password_reset_module}.sh"
done
unset _PASSWORD_RESET_MODULE_DIR _password_reset_module
