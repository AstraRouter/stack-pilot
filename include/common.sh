#!/usr/bin/env bash

LNMP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LNMP_SRC_DIR="${LNMP_SRC_DIR:-${LNMP_ROOT_DIR}/src}"
LNMP_LOG_FILE="${LNMP_LOG_FILE:-${LNMP_ROOT_DIR}/install.log}"
LNMP_ERROR_LOG_FILE="${LNMP_ERROR_LOG_FILE:-${LNMP_ROOT_DIR}/install-error.log}"
LNMP_STATE_DIR="${LNMP_STATE_DIR:-${LNMP_ROOT_DIR}/.state}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_BOLD=''
fi

_COMMON_MODULE_DIR="${LNMP_ROOT_DIR}/include/common"
for _common_module in core values terminal prompt config packages source state filesystem; do
  # shellcheck source=/dev/null
  source "${_COMMON_MODULE_DIR}/${_common_module}.sh"
done
unset _COMMON_MODULE_DIR _common_module
