#!/usr/bin/env bash

safe_state_name() {
  printf '%s' "$1" | tr '/: ' '___'
}

mark_step_done() {
  local step="$1"
  mkdir -p "${LNMP_STATE_DIR}"
  date '+%F %T' > "${LNMP_STATE_DIR}/$(safe_state_name "${step}").done"
}

is_step_done() {
  local step="$1"
  [[ -f "${LNMP_STATE_DIR}/$(safe_state_name "${step}").done" ]]
}

clear_step_done() {
  local step="$1"
  local marker="${LNMP_STATE_DIR}/$(safe_state_name "${step}").done"
  [[ -f "${marker}" ]] && rm -f "${marker}"
  return 0
}

run_step_once() {
  local step="$1"
  shift
  if is_step_done "${step}"; then
    ok "Skipping completed step: ${step}"
    return 0
  fi
  "$@"
  mark_step_done "${step}"
}
