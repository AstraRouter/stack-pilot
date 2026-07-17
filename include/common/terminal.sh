#!/usr/bin/env bash

render_select_options() {
  local selected_index="$1"
  shift
  local index=0 entry marker
  for entry in "$@"; do
    terminal_clear_line
    printf '\r' >&2
    if [[ "${index}" -eq "${selected_index}" ]]; then
      marker=">"
      printf '  %s %s%s%s\n' "${marker}" "${C_BOLD}" "$(entry_label "${entry}")" "${C_RESET}" >&2
    else
      marker=" "
      printf '  %s %s\n' "${marker}" "$(entry_label "${entry}")" >&2
    fi
    index=$((index + 1))
  done
}

render_multi_select_options() {
  local cursor_index="$1"
  local selected="$2"
  shift 2
  local index=0 entry value label cursor checked
  for entry in "$@"; do
    terminal_clear_line
    printf '\r' >&2
    value="$(entry_value "${entry}")"
    label="$(entry_label "${entry}")"
    cursor=" "
    checked="[ ]"
    [[ "${selected}" == *" ${value} "* ]] && checked="[*]"
    [[ "${index}" -eq "${cursor_index}" ]] && cursor=">"
    if [[ "${index}" -eq "${cursor_index}" ]]; then
      printf '  %s %s %s%s%s\n' "${cursor}" "${checked}" "${C_BOLD}" "${label}" "${C_RESET}" >&2
    else
      printf '  %s %s %s\n' "${cursor}" "${checked}" "${label}" >&2
    fi
    index=$((index + 1))
  done
}

terminal_cursor_hide() {
  [[ -t 2 ]] || return 0
  tput civis >&2 2>/dev/null || printf '\033[?25l' >&2
}

terminal_cursor_show() {
  [[ -t 2 ]] || return 0
  tput cnorm >&2 2>/dev/null || printf '\033[?25h' >&2
}

terminal_move_up() {
  local lines="$1"
  ((lines > 0)) || return 0
  tput cuu "${lines}" >&2 2>/dev/null || printf '\033[%sA' "${lines}" >&2
}

terminal_move_down() {
  local lines="$1"
  ((lines > 0)) || return 0
  tput cud "${lines}" >&2 2>/dev/null || printf '\033[%sB' "${lines}" >&2
}

terminal_clear_line() {
  tput el >&2 2>/dev/null || printf '\033[K' >&2
}

redraw_select_menu() {
  local index="$1"
  local previous_index="$2"
  shift 2
  local entries=("$@") low high current
  terminal_cursor_hide
  terminal_move_up $((${#entries[@]} + 1))
  low="${previous_index}"; high="${index}"
  ((low > high)) && { current="${low}"; low="${high}"; high="${current}"; }
  terminal_move_down "${low}"
  render_select_options "$((index == low ? 0 : -1))" "${entries[low]}"
  terminal_move_down "$((high - low - 1))"
  render_select_options "$((index == high ? 0 : -1))" "${entries[high]}"
  terminal_move_down "$((${#entries[@]} - high))"
  terminal_cursor_show
  return 0
}

redraw_multi_select_menu() {
  local index="$1"
  local selected="$2"
  local previous_index="$3"
  shift 3
  local entries=("$@") low high current
  terminal_cursor_hide
  terminal_move_up $((${#entries[@]} + 1))
  low="${previous_index}"; high="${index}"
  ((low > high)) && { current="${low}"; low="${high}"; high="${current}"; }
  terminal_move_down "${low}"
  render_multi_select_options "$((index == low ? 0 : -1))" "${selected}" "${entries[low]}"
  terminal_move_down "$((high - low - 1))"
  if ((high != low)); then
    render_multi_select_options "$((index == high ? 0 : -1))" "${selected}" "${entries[high]}"
  fi
  terminal_move_down "$((${#entries[@]} - high))"
  terminal_cursor_show
  return 0
}

read_arrow_key() {
  local key rest
  IFS= read -rsn1 key
  if [[ "${key}" == $'\033' ]]; then
    IFS= read -rsn2 -t 1 rest || true
    key+="${rest}"
  fi
  printf '%s' "${key}"
}

print_header() {
  clear 2>/dev/null || true
  printf '%s\n' "============================================================"
  printf '%s\n' " LNMP Interactive Installer"
  printf '%s\n' "============================================================"
}
