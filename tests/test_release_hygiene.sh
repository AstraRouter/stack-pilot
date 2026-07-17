#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "${ROOT_DIR}/options.example.conf" ]] || fail "options.example.conf is missing"

for key in mysql_password mariadb_password redis_password memcached_password; do
  grep -q "^${key}=$" "${ROOT_DIR}/options.example.conf" || fail "${key} must be empty in options.example.conf"
done

for ignored in options.conf .state/ src/ .superpowers/ task_plan.md findings.md progress.md; do
  grep -Fxq "${ignored}" "${ROOT_DIR}/.gitignore" || fail "${ignored} is not listed in .gitignore"
done

cjk_pattern=$'[\xE4-\xE9][\x80-\xBF][\x80-\xBF]'
if LC_ALL=C grep -R -n "${cjk_pattern}" \
  --exclude-dir=.superpowers \
  --exclude-dir=superpowers \
  --exclude=task_plan.md \
  --exclude=findings.md \
  --exclude=progress.md \
  "${ROOT_DIR}" >/dev/null 2>&1; then
  fail "public source and documentation must use English text only"
fi

[[ -s "${ROOT_DIR}/LICENSE" ]] || fail "LICENSE is missing"
grep -q 'Apache License' "${ROOT_DIR}/LICENSE" || fail "LICENSE is not Apache-2.0"
[[ -s "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" ]] || fail "third-party notices are missing"

echo "PASS: release hygiene"
