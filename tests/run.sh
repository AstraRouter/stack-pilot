#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
passed=0

for test_file in "${ROOT_DIR}"/tests/test_*.sh; do
  printf 'RUN  %s\n' "$(basename "${test_file}")"
  if bash "${test_file}"; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
  fi
done

while IFS= read -r shell_file; do
  if ! bash -n "${shell_file}"; then
    failures=$((failures + 1))
  fi
done < <(find "${ROOT_DIR}" -type f -name '*.sh' ! -name '._*' -not -path '*/src/*' -not -path '*/.git/*' | sort)

if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r shell_file; do
    shellcheck -x "${shell_file}" || failures=$((failures + 1))
  done < <(find "${ROOT_DIR}" -type f -name '*.sh' ! -name '._*' -not -path '*/src/*' -not -path '*/.git/*' | sort)
else
  printf 'SKIP shellcheck (not installed)\n'
fi

printf '\nTests passed: %d, failures: %d\n' "${passed}" "${failures}"
((failures == 0))
