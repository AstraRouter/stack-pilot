#!/usr/bin/env bash

# shellcheck source=/dev/null
source "${LNMP_ROOT_DIR}/include/nginx/policy.sh"

_VHOST_MODULE_DIR="${LNMP_ROOT_DIR}/include/vhost"
for _vhost_module in paths render ssl operations; do
  # shellcheck source=/dev/null
  source "${_VHOST_MODULE_DIR}/${_vhost_module}.sh"
done
unset _VHOST_MODULE_DIR _vhost_module
