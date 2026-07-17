#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/include/common.sh"

declare -F terminal_move_down >/dev/null || {
  echo "FAIL: terminal_move_down must be implemented by the terminal module" >&2
  exit 1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

terminal_cursor_hide() { :; }
terminal_cursor_show() { :; }
terminal_move_up() { printf 'UP:%s\n' "$1" >&2; }
terminal_move_down() { printf 'DOWN:%s\n' "$1" >&2; }
terminal_clear_line() { printf 'CLEAR\n' >&2; }

output="$(redraw_multi_select_menu 1 " nginx " 0 \
  "nginx|Nginx" \
  "php|PHP" \
  "mysql|MySQL" 2>&1)"

clear_count="$(printf '%s\n' "${output}" | grep -c '^CLEAR$')"
assert_eq "2" "${clear_count}" "moving cursor should redraw only previous and current multi-select rows"
grep -q '^UP:4$' <<< "${output}" || fail "multi-select redraw should move to the first changed row"
grep -q '^DOWN:2$' <<< "${output}" || fail "multi-select redraw should restore cursor below the help line"

output="$(redraw_select_menu 1 0 \
  "nginx|Nginx" \
  "php|PHP" \
  "mysql|MySQL" 2>&1)"

clear_count="$(printf '%s\n' "${output}" | grep -c '^CLEAR$')"
assert_eq "2" "${clear_count}" "moving cursor should redraw only previous and current select rows"

read_arrow_key() { printf '%s' $'\033[D'; }
back_value="$(LNMP_FORCE_INTERACTIVE=1 LNMP_ALLOW_BACK=1 prompt_select "Test back navigation" one "one|Option one" "two|Option two" 2>/dev/null)"
assert_eq "__BACK__" "${back_value}" "left arrow should return from an enabled single-select page"
back_value="$(LNMP_FORCE_INTERACTIVE=1 LNMP_ALLOW_BACK=1 prompt_multi_select "Test back navigation" one "one|Option one" "two|Option two" 2>/dev/null)"
assert_eq "__BACK__" "${back_value}" "left arrow should return from an enabled multi-select page"

echo "PASS: terminal rendering"
