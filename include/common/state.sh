#!/usr/bin/env bash

# Map an installation step name onto its marker filename.
#
# Only ':' is translated, and because '_' is not in the accepted alphabet the
# mapping is injective: two different step names can never share a marker and
# silently skip one another. Anything outside the alphabet is rejected instead
# of being folded onto an existing name.
#
# uninstall_lib derives its cleanup prefixes through this same function, so the
# translation is a shared contract rather than a duplicated assumption.
safe_state_name() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9.:-]*$ ]] ||
    die "Invalid installation step name '${name}': use letters, digits, dot, dash, and colon only"
  printf '%s' "${name//:/_}"
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
  local marker
  marker="${LNMP_STATE_DIR}/$(safe_state_name "${step}").done"
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
