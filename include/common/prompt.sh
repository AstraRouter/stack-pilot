#!/usr/bin/env bash

interactive_prompt_enabled() {
  [[ "${LNMP_SIMPLE_PROMPT:-}" != "1" ]] && { [[ -t 0 ]] || [[ "${LNMP_FORCE_INTERACTIVE:-0}" == "1" ]]; }
}

prompt_select() {
  local message="$1"
  local default="$2"
  shift 2
  local entries=("$@")
  local count="${#entries[@]}"
  local index previous_index key value choices entry
  ((count > 0)) || return 1

  if ! interactive_prompt_enabled; then
    choices=""
    for entry in "${entries[@]}"; do
      value="$(entry_value "${entry}")"
      choices="${choices:+${choices} }${value}"
      printf '  %s. %s\n' "${value}" "$(entry_label "${entry}")" >&2
    done
    prompt_choice "${message}" "${choices}" "${default}"
    return $?
  fi

  index="$(select_default_index "${default}" "${entries[@]}")"
  printf '? %s\n' "${message}" >&2
  render_select_options "${index}" "${entries[@]}"
  if [[ "${LNMP_ALLOW_BACK:-0}" == "1" ]]; then
    printf 'Use Up/Down to select, Left to go back, and Enter to confirm.\n' >&2
  else
    printf 'Use the arrow keys to select and Enter to confirm.\n' >&2
  fi
  while :; do
    key="$(read_arrow_key)"
    previous_index="${index}"
    case "${key}" in
      $'\033[A'|k)
        index=$((index - 1))
        ((index < 0)) && index=$((count - 1))
        ;;
      $'\033[B'|$'\033[C'|j|l)
        index=$((index + 1))
        ((index >= count)) && index=0
        ;;
      $'\033[D'|h)
        if [[ "${LNMP_ALLOW_BACK:-0}" == "1" ]]; then
          printf '\n' >&2
          printf '%s' '__BACK__'
          return 0
        fi
        index=$((index - 1))
        ((index < 0)) && index=$((count - 1))
        ;;
      ""|$'\n'|$'\r')
        entry="${entries[$index]}"
        printf '\n' >&2
        entry_value "${entry}"
        return 0
        ;;
      q|$'\003')
        printf '\n' >&2
        return 1
        ;;
      *) continue ;;
    esac
    redraw_select_menu "${index}" "${previous_index}" "${entries[@]}"
  done
}

prompt_multi_select() {
  local message="$1"
  local default="$2"
  shift 2
  local entries=("$@")
  local count="${#entries[@]}"
  local index=0 previous_index selected key entry choices value normalized
  ((count > 0)) || return 1
  choices=""
  for entry in "${entries[@]}"; do
    value="$(entry_value "${entry}")"
    choices="${choices:+${choices} }${value}"
  done
  selected=" $(normalize_values "${default}" "${choices}" 2>/dev/null || printf '%s' "${default}") "

  if ! interactive_prompt_enabled; then
    for entry in "${entries[@]}"; do
      value="$(entry_value "${entry}")"
      printf '  %s. %s\n' "${value}" "$(entry_label "${entry}")" >&2
    done
    while :; do
      value="$(prompt_input "${message}" "${default}")"
      if normalized="$(normalize_values "${value}" "${choices}")"; then
        printf '%s' "${normalized}"
        return 0
      fi
      warn "Invalid input"
    done
  fi

  printf '? %s\n' "${message}" >&2
  render_multi_select_options "${index}" "${selected}" "${entries[@]}"
  if [[ "${LNMP_ALLOW_BACK:-0}" == "1" ]]; then
    printf 'Use Up/Down to move, Space to toggle, Left to go back, and Enter to confirm.\n' >&2
  else
    printf 'Use the arrow keys to move, Space to toggle, and Enter to confirm.\n' >&2
  fi
  while :; do
    key="$(read_arrow_key)"
    previous_index="${index}"
    case "${key}" in
      $'\033[A'|k)
        index=$((index - 1))
        ((index < 0)) && index=$((count - 1))
        ;;
      $'\033[B'|$'\033[C'|j|l)
        index=$((index + 1))
        ((index >= count)) && index=0
        ;;
      $'\033[D'|h)
        if [[ "${LNMP_ALLOW_BACK:-0}" == "1" ]]; then
          printf '\n' >&2
          printf '%s' '__BACK__'
          return 0
        fi
        index=$((index - 1))
        ((index < 0)) && index=$((count - 1))
        ;;
      " ")
        entry="${entries[$index]}"
        selected=" $(toggle_multi_value "${selected}" "$(entry_value "${entry}")") "
        ;;
      ""|$'\n'|$'\r')
        selected="$(printf '%s' "${selected}" | awk '{$1=$1; print}')"
        [[ -n "${selected}" ]] || { warn "Select at least one option"; continue; }
        printf '\n' >&2
        printf '%s' "${selected}"
        return 0
        ;;
      q|$'\003')
        printf '\n' >&2
        return 1
        ;;
      *) continue ;;
    esac
    redraw_multi_select_menu "${index}" "${selected}" "${previous_index}" "${entries[@]}"
  done
}

prompt_input() {
  local message="$1"
  local default="${2:-}"
  local value
  if [[ -n "${default}" ]]; then
    read -r -p "? ${message} [${default}]: " value
    printf '%s' "${value:-${default}}"
  else
    read -r -p "? ${message}: " value
    printf '%s' "${value}"
  fi
}

prompt_yes_no() {
  local message="$1"
  local default="${2:-y}"
  local suffix value normalized
  if interactive_prompt_enabled; then
    prompt_select "${message}" "${default}" "y|Yes" "n|No"
    return $?
  fi
  [[ "${default}" == "y" ]] && suffix="Y/n" || suffix="y/N"
  while :; do
    read -r -p "? ${message} [${suffix}]: " value
    if normalized="$(normalize_yes_no "${value}" "${default}")"; then
      printf '%s' "${normalized}"
      return 0
    fi
    warn "Enter y or n"
  done
}

prompt_choice() {
  local message="$1"
  local choices="$2"
  local default="$3"
  local value
  while :; do
    read -r -p "? ${message} [${default}]: " value
    value="${value:-${default}}"
    if validate_choice "${value}" "${choices}"; then
      printf '%s' "${value}"
      return 0
    fi
    warn "Invalid input. Available values: ${choices}"
  done
}
