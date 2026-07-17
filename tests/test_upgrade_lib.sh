#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"
source "${ROOT_DIR}/include/upgrade_lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
backup_dir="${tmp_dir}/backups"
LNMP_STATE_DIR="${tmp_dir}/state"
UPGRADE_SKIP_SERVICE_CONTROL=1
test_install_dir="${tmp_dir}/services/example"

reset_install_tree() {
  rm -rf "${test_install_dir}"
  mkdir -p "${test_install_dir}"
  printf 'old\n' > "${test_install_dir}/version.txt"
}

installer_success() { printf 'new\n' > "${test_install_dir}/version.txt"; }
installer_failure() { printf 'broken\n' > "${test_install_dir}/version.txt"; return 1; }
health_success() { grep -q '^new$' "${test_install_dir}/version.txt"; }
health_failure() { return 1; }
preserve_test_config() { restore_snapshot_paths "$1" "$2" etc; }

if validate_upgrade_install_dir /; then fail "filesystem root accepted as upgrade target"; fi
if validate_upgrade_install_dir relative/path; then fail "relative upgrade target accepted"; fi
validate_upgrade_install_dir "${test_install_dir}" || fail "safe absolute component path rejected"

reset_install_tree
mkdir -p "${test_install_dir}/etc"
printf 'custom=true\n' > "${test_install_dir}/etc/example.conf"
installer_with_config_reset() {
  printf 'new\n' > "${test_install_dir}/version.txt"
  printf 'default=true\n' > "${test_install_dir}/etc/example.conf"
}
transactional_component_upgrade Example example:2 "${test_install_dir}" '' health_success preserve_test_config installer_with_config_reset
grep -q '^new$' "${test_install_dir}/version.txt" || fail "successful transaction did not retain new tree"
grep -q '^custom=true$' "${test_install_dir}/etc/example.conf" || fail "successful upgrade did not restore custom config"
is_step_done example:2 || fail "successful transaction did not mark state complete"

reset_install_tree
mark_step_done example:3
if transactional_component_upgrade Example example:3 "${test_install_dir}" '' health_success preserve_no_upgrade_config installer_failure >/dev/null 2>&1; then
  fail "installer failure reported upgrade success"
fi
grep -q '^old$' "${test_install_dir}/version.txt" || fail "installer failure did not restore old tree"
is_step_done example:3 || fail "rollback should restore a previously completed state marker"

reset_install_tree
if transactional_component_upgrade Example example:4 "${test_install_dir}" '' health_failure preserve_no_upgrade_config installer_success >/dev/null 2>&1; then
  fail "health-check failure reported upgrade success"
fi
grep -q '^old$' "${test_install_dir}/version.txt" || fail "health-check failure did not restore old tree"
is_step_done example:4 && fail "failed health transaction wrote completed state"

snapshot_count="$(find "${backup_dir}" -type f -name 'example-tree-*.tar.gz' | wc -l | awk '{$1=$1; print}')"
[[ "${snapshot_count}" == "3" ]] || fail "each transaction should retain one rollback snapshot"

echo "PASS: upgrade transaction helpers"
