#!/usr/bin/env bash

_PHP_EXT_MODULE_DIR="${LNMP_ROOT_DIR}/include/php_extensions"
for _php_ext_module in catalog profiles configure pecl; do
  # shellcheck source=/dev/null
  source "${_PHP_EXT_MODULE_DIR}/${_php_ext_module}.sh"
done
unset _PHP_EXT_MODULE_DIR _php_ext_module
