#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

BH_SCREEN_ACTIVE=false
BH_SCREEN_CLEAR=false
BH_UNICODE=false
BH_SAFE_TEXT=""
BH_MENU_HIGHLIGHT=true
BH_CONTENT_WIDTH=68
BH_LEFT_PAD=2
declare -a BH_MENU_KEYS=()
declare -a BH_MENU_LABELS=()
declare -a BH_MENU_DESCRIPTIONS=()

if [[ "$(locale charmap 2>/dev/null || true)" =~ ^UTF-?8$ ]]; then
  BH_UNICODE=true
fi
case "${TERM:-dumb}" in
  linux|cons25*) BH_UNICODE=false ;;
esac
[[ "${BLACKHOST_ASCII:-0}" == "1" ]] && BH_UNICODE=false
[[ "${BLACKHOST_UNICODE:-0}" == "1" ]] && BH_UNICODE=true
if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]; then
  BH_MENU_HIGHLIGHT=false
fi
[[ "${BLACKHOST_MENU_HIGHLIGHT:-}" == "1" ]] && BH_MENU_HIGHLIGHT=true

ui_safe_text() {
  BH_SAFE_TEXT=$1
  [[ "$BH_UNICODE" == true ]] && return 0
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ą/a}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ć/c}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ę/e}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ł/l}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ń/n}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ó/o}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ś/s}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ź/z}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//ż/z}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ą/A}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ć/C}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ę/E}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ł/L}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ń/N}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ó/O}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ś/S}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ź/Z}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//Ż/Z}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//·/-}
  BH_SAFE_TEXT=${BH_SAFE_TEXT//…/...}
}

ui_measure_layout() {
  local columns=80
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    columns=$(tput cols 2>/dev/null || printf '80')
  fi
  [[ "$columns" =~ ^[0-9]+$ ]] || columns=80

  BH_CONTENT_WIDTH=68
  ((columns < 72)) && BH_CONTENT_WIDTH=$((columns - 4))
  ((BH_CONTENT_WIDTH < 44)) && BH_CONTENT_WIDTH=44
  BH_LEFT_PAD=2
  return 0
}

ui_indent() {
  printf '%*s' "$BH_LEFT_PAD" ''
}

ui_cursor_show() {
  [[ "$BH_SCREEN_ACTIVE" == true || "$BH_SCREEN_CLEAR" == true ]] || return 0
  command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null || true
}

ui_cursor_hide() {
  [[ "$BH_SCREEN_ACTIVE" == true || "$BH_SCREEN_CLEAR" == true ]] || return 0
  command -v tput >/dev/null 2>&1 && tput civis 2>/dev/null || true
}

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  BH_RESET=$'\033[0m'
  BH_BOLD=$'\033[1m'
  BH_DIM=$'\033[2m'
  BH_RED=$'\033[1;31m'
  BH_GREEN=$'\033[1;32m'
  BH_YELLOW=$'\033[1;33m'
  BH_BLUE=$'\033[38;5;33m'
  BH_MUTED=$'\033[38;5;244m'
  BH_WHITE=$'\033[1;37m'
  BH_SELECTED=$'\033[1;97m'
else
  BH_RESET=""
  BH_BOLD=""
  BH_DIM=""
  BH_RED=""
  BH_GREEN=""
  BH_YELLOW=""
  BH_BLUE=""
  BH_MUTED=""
  BH_WHITE=""
  BH_SELECTED=""
fi

ui_screen_enter() {
  [[ -t 0 && -t 1 ]] || return 0
  [[ "${TERM:-dumb}" != "dumb" ]] || return 0
  [[ "${BLACKHOST_NO_ALT_SCREEN:-0}" != "1" ]] || return 0

  if [[ "${BLACKHOST_FORCE_CLEAR:-0}" != "1" && "${TERM:-}" != "linux" ]] \
    && command -v tput >/dev/null 2>&1 && tput smcup 2>/dev/null; then
    BH_SCREEN_ACTIVE=true
    tput civis 2>/dev/null || true
  else
    BH_SCREEN_CLEAR=true
    printf '\033[H\033[2J'
    command -v tput >/dev/null 2>&1 && tput civis 2>/dev/null || true
  fi
}

ui_screen_leave() {
  if [[ "$BH_SCREEN_ACTIVE" == true ]]; then
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
  elif [[ "$BH_SCREEN_CLEAR" == true ]]; then
    command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null || true
  else
    return 0
  fi
  BH_SCREEN_ACTIVE=false
  BH_SCREEN_CLEAR=false
}

ui_refresh() {
  if [[ "$BH_SCREEN_ACTIVE" == true || "$BH_SCREEN_CLEAR" == true ]]; then
    printf '\033[H\033[2J'
  else
    printf '\n'
  fi
}

ui_rule() {
  local width=${1:-$BH_CONTENT_WIDTH} char="-" line
  [[ "$BH_UNICODE" == true ]] && char="─"
  printf -v line "%${width}s" ''
  line=${line// /$char}
  ui_indent
  printf '%s%s%s\n' "$BH_MUTED" "$line" "$BH_RESET"
}

ui_logo() {
  local line logo_width=0 padding
  local -a logo=(
    ' ____  _            _    _    _           _   '
    '|  _ \| |          | |  | |  | |         | |  '
    '| |_) | | __ _  ___| | _| |__| | ___  ___| |_ '
    '|  _ <| |/ _` |/ __| |/ /  __  |/ _ \/ __| __|'
    '| |_) | | (_| | (__|   <| |  | | (_) \__ \ |_ '
    '|____/|_|\__,_|\___|_|\_\_|  |_|\___/|___/\__|'
  )
  for line in "${logo[@]}"; do
    ((${#line} > logo_width)) && logo_width=${#line}
  done
  padding=$((BH_LEFT_PAD + (BH_CONTENT_WIDTH - logo_width) / 2))
  ((padding < BH_LEFT_PAD)) && padding=$BH_LEFT_PAD

  printf '\n%s' "$BH_BLUE"
  for line in "${logo[@]}"; do
    printf '%*s%s\n' "$padding" '' "$line"
  done
  printf '%s\n' "$BH_RESET"
}

ui_header() {
  local context=${1:-SERVER TOOLKIT} version_label gap
  ui_menu_reset
  ui_measure_layout
  ui_refresh
  ui_logo
  ui_safe_text "$context"
  context=$BH_SAFE_TEXT
  version_label="CLI v${BLACKHOST_VERSION:-dev}"
  gap=$((BH_CONTENT_WIDTH - ${#context} - ${#version_label}))
  ((gap < 1)) && gap=1
  ui_indent
  printf '%s%s%s%*s%s%s%s\n' \
    "$BH_WHITE" "$context" "$BH_RESET" "$gap" '' "$BH_MUTED" "$version_label" "$BH_RESET"
  ui_rule
}

ui_section() {
  local label=$1
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  printf '\n'
  ui_indent
  printf '%s%s%s\n' "$BH_MUTED" "$label" "$BH_RESET"
}

ui_info() {
  local icon="i" message="$*"
  [[ "$BH_UNICODE" == true ]] && icon="●"
  ui_safe_text "$message"
  message=$BH_SAFE_TEXT
  ui_indent
  printf '%s%s%s  %s\n' "$BH_BLUE" "$icon" "$BH_RESET" "$message"
}

ui_success() {
  local icon="OK" message="$*"
  [[ "$BH_UNICODE" == true ]] && icon="✓"
  ui_safe_text "$message"
  message=$BH_SAFE_TEXT
  ui_indent
  printf '%s%s%s  %s\n' "$BH_GREEN" "$icon" "$BH_RESET" "$message"
}

ui_warn() {
  local icon="!" message="$*"
  [[ "$BH_UNICODE" == true ]] && icon="▲"
  ui_safe_text "$message"
  message=$BH_SAFE_TEXT
  ui_indent
  printf '%s%s%s  %s\n' "$BH_YELLOW" "$icon" "$BH_RESET" "$message"
}

ui_error() {
  local icon="X" message="$*"
  [[ "$BH_UNICODE" == true ]] && icon="✕"
  ui_safe_text "$message"
  message=$BH_SAFE_TEXT
  ui_indent >&2
  printf '%s%s%s  %s\n' "$BH_RED" "$icon" "$BH_RESET" "$message" >&2
}

ui_menu_reset() {
  BH_MENU_KEYS=()
  BH_MENU_LABELS=()
  BH_MENU_DESCRIPTIONS=()
}

ui_option_render() {
  local key=$1 label=$2 description=${3:-} selected=${4:-false}
  local label_width=30 padding select_char=">" label_color="" description_color="$BH_DIM"
  local max_description used_width trailing_width
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$description"
  description=$BH_SAFE_TEXT
  [[ "$BH_UNICODE" == true ]] && select_char="›"
  max_description=$((BH_CONTENT_WIDTH - 39))
  if ((max_description <= 0)); then
    description=""
  elif ((${#description} > max_description)); then
    if ((max_description >= 4)); then
      description="${description:0:max_description-3}..."
    else
      description=${description:0:max_description}
    fi
  fi
  padding=$((label_width - ${#label}))
  ((padding < 1)) && padding=1
  ui_indent
  if [[ "$selected" == true && "$BH_MENU_HIGHLIGHT" == true ]]; then
    label_color=$BH_SELECTED
  fi
  if [[ "$selected" == true ]]; then
    printf '%s%s%s ' "$BH_BLUE" "$select_char" "$BH_RESET"
  else
    printf '  '
  fi
  printf '%s[%2s]%s  %s%s%s' \
    "$BH_BLUE$BH_BOLD" "$key" "$BH_RESET" \
    "$label_color" "$label" "$BH_RESET"
  printf '%*s' "$padding" ''
  if [[ -n "$description" ]]; then
    printf ' %s%s%s' "$description_color" "$description" "$BH_RESET"
  fi
  used_width=38
  [[ -n "$description" ]] && used_width=$((used_width + 1 + ${#description}))
  trailing_width=$((BH_CONTENT_WIDTH - used_width))
  ((trailing_width > 0)) && printf '%*s' "$trailing_width" ''
  if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    printf '%s\033[K\n' "$BH_RESET"
  else
    printf '%s\n' "$BH_RESET"
  fi
}

ui_option() {
  local key=$1 label=$2 description=${3:-}
  BH_MENU_KEYS+=("$key")
  BH_MENU_LABELS+=("$label")
  BH_MENU_DESCRIPTIONS+=("$description")
  ui_option_render "$key" "$label" "$description" false
}

ui_menu_redraw_option() {
  local index=$1 selected=$2 count=$3 distance
  distance=$((count + 1 - index))
  printf '\0337\033[%dA\r' "$distance"
  ui_option_render \
    "${BH_MENU_KEYS[index]}" "${BH_MENU_LABELS[index]}" \
    "${BH_MENU_DESCRIPTIONS[index]}" "$selected"
  printf '\0338'
}

ui_status_row() {
  local label=$1 state=$2 details=${3:-} marker color text
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$details"
  details=$BH_SAFE_TEXT
  case "$state" in
    ok) marker="ON"; color=$BH_GREEN; text="aktywny" ;;
    warn) marker="!!"; color=$BH_YELLOW; text="wymaga uwagi" ;;
    *) marker="--"; color=$BH_MUTED; text="niewykryty" ;;
  esac
  [[ "$BH_UNICODE" == true && "$state" == "ok" ]] && marker="●"
  [[ "$BH_UNICODE" == true && "$state" == "warn" ]] && marker="▲"
  [[ "$BH_UNICODE" == true && "$state" != "ok" && "$state" != "warn" ]] && marker="○"
  ui_indent
  printf '%s%-2s%s  %-25s %-14s %s%s%s\n' \
    "$color" "$marker" "$BH_RESET" "$label" "$text" "$BH_DIM" "$details" "$BH_RESET"
}

ui_key_value() {
  local label=$1 value=$2 label_width=12 padding
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$value"
  value=$BH_SAFE_TEXT
  padding=$((label_width - ${#label}))
  ((padding < 1)) && padding=1
  ui_indent
  printf '%s%s%s' "$BH_MUTED" "$label" "$BH_RESET"
  printf '%*s' "$padding" ''
  printf ' %s\n' "$value"
}

ui_summary_group() {
  local label=$1
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  printf '\n'
  ui_indent
  printf '%s%s%s\n' "$BH_BLUE$BH_BOLD" "$label" "$BH_RESET"
}

ui_summary_row() {
  local label=$1 value=$2 label_width=18 padding
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$value"
  value=$BH_SAFE_TEXT
  padding=$((label_width - ${#label}))
  ((padding < 1)) && padding=1
  ui_indent
  printf '  %s%s%s' "$BH_MUTED" "$label" "$BH_RESET"
  printf '%*s' "$padding" ''
  printf ' %s\n' "$value"
}

ui_state_value() {
  local state=$1 enabled_text=${2:-Włączony} disabled_text=${3:-Wyłączony}
  ui_safe_text "$enabled_text"
  enabled_text=$BH_SAFE_TEXT
  ui_safe_text "$disabled_text"
  disabled_text=$BH_SAFE_TEXT
  if [[ "$state" == true ]]; then
    printf '%s%s%s' "$BH_GREEN" "$enabled_text" "$BH_RESET"
  else
    printf '%s%s%s' "$BH_MUTED" "$disabled_text" "$BH_RESET"
  fi
}

ui_metric_value() {
  local label=$1 value=$2 unit=${3:-} label_width=12 padding
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$value"
  value=$BH_SAFE_TEXT
  ui_safe_text "$unit"
  unit=$BH_SAFE_TEXT
  padding=$((label_width - ${#label}))
  ((padding < 1)) && padding=1
  ui_indent
  printf '%s%s%s' "$BH_MUTED" "$label" "$BH_RESET"
  printf '%*s' "$padding" ''
  printf ' %9s %-5s\n' "$value" "$unit"
}

ui_three_columns() {
  local color=$1 first=$2 second=$3 third=$4 width=18 text padding index
  ui_safe_text "$first"
  first=$BH_SAFE_TEXT
  ui_safe_text "$second"
  second=$BH_SAFE_TEXT
  ui_safe_text "$third"
  third=$BH_SAFE_TEXT
  local -a cells=("$first" "$second" "$third")
  ui_indent
  printf '%s' "$color"
  for index in 0 1 2; do
    text=${cells[$index]}
    printf '%s' "$text"
    if ((index < 2)); then
      padding=$((width - ${#text}))
      ((padding < 2)) && padding=2
      printf '%*s' "$padding" ''
    fi
  done
  printf '%s\n' "$BH_RESET"
}

ui_hyperlink() {
  local url=$1 label=${2:-$1}
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_indent
  if [[ -t 1 && "${TERM:-dumb}" != "dumb" && "$url" =~ ^https?://[^[:space:][:cntrl:]]+$ ]]; then
    printf '%s\033]8;;%s\033\\%s\033]8;;\033\\%s\n' \
      "$BH_BLUE" "$url" "$label" "$BH_RESET"
  else
    printf '%s%s%s\n' "$BH_BLUE" "$url" "$BH_RESET"
  fi
}

ui_input_label() {
  local marker=">"
  [[ "$BH_UNICODE" == true ]] && marker="›"
  printf '\n'
  ui_indent
  printf '%s%s%s ' "$BH_BLUE" "$marker" "$BH_RESET"
}

ui_pause() {
  local mode=${1:-enter} key message="Naciśnij Enter, aby wrócić..."
  [[ "$mode" == "escape" ]] && message="Naciśnij Enter lub Esc, aby wrócić..."
  ui_safe_text "$message"
  message=$BH_SAFE_TEXT
  ui_input_label
  printf '%s' "$message"
  ui_cursor_show
  if [[ "$mode" == "escape" && -t 0 ]]; then
    while IFS= read -rsn1 key; do
      [[ -z "$key" || "$key" == $'\e' ]] && break
    done
  else
    IFS= read -r key
  fi
  ui_cursor_hide
}

ui_prompt() {
  local __name=$1 label=$2 default_value=${3:-} value
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$default_value"
  default_value=$BH_SAFE_TEXT

  ui_input_label
  if [[ -n "$default_value" ]]; then
    printf '%s %s[%s]%s: ' "$label" "$BH_DIM" "$default_value" "$BH_RESET"
  else
    printf '%s: ' "$label"
  fi
  ui_cursor_show
  IFS= read -r value
  ui_cursor_hide
  value=${value:-$default_value}
  printf -v "$__name" '%s' "$value"
}

ui_secret() {
  local __name=$1 label=$2 placeholder=${3:-} value
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  ui_safe_text "$placeholder"
  placeholder=$BH_SAFE_TEXT
  ui_input_label
  printf '%s' "$label"
  [[ -n "$placeholder" ]] && printf ' %s[%s]%s' "$BH_DIM" "$placeholder" "$BH_RESET"
  printf ': '
  ui_cursor_show
  IFS= read -r -s value
  ui_cursor_hide
  printf '\n'
  printf -v "$__name" '%s' "$value"
}

ui_confirm() {
  local label=$1 default_value=${2:-n} answer suffix
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  [[ "$default_value" == "y" ]] && suffix="[T/n]" || suffix="[t/N]"
  ui_input_label
  printf '%s %s%s%s: ' "$label" "$BH_DIM" "$suffix" "$BH_RESET"
  ui_cursor_show
  IFS= read -r answer
  ui_cursor_hide
  answer=${answer:-$default_value}
  [[ "$answer" =~ ^([TtYy]|[Tt][Aa][Kk]|[Yy][Ee][Ss])$ ]]
}

ui_menu_prompt() {
  local __name=$1 value key sequence index selected=0 previous count=${#BH_MENU_KEYS[@]}

  if [[ ! -t 0 || ! -t 1 || "${TERM:-dumb}" == "dumb" || "$count" -eq 0 ]]; then
    local fallback_prompt="Wybierz opcję: "
    ui_safe_text "$fallback_prompt"
    fallback_prompt=$BH_SAFE_TEXT
    ui_input_label
    printf '%s' "$fallback_prompt"
    ui_cursor_show
    IFS= read -r value
    ui_cursor_hide
    value=${value%$'\r'}
    printf -v "$__name" '%s' "$value"
    return 0
  fi

  printf '\n'
  ui_indent
  if [[ "$BH_UNICODE" == true ]]; then
    printf '%s↑/↓%s wybierz  %sEnter%s zatwierdź  %sEsc%s wróć' \
      "$BH_BLUE" "$BH_RESET" "$BH_BLUE" "$BH_RESET" "$BH_BLUE" "$BH_RESET"
  else
    printf '%sGora/dol%s wybierz  %sEnter%s zatwierdz  %sEsc%s wroc' \
      "$BH_BLUE" "$BH_RESET" "$BH_BLUE" "$BH_RESET" "$BH_BLUE" "$BH_RESET"
  fi
  ui_menu_redraw_option "$selected" true "$count"

  while :; do
    key=""
    if ! IFS= read -rsn1 key; then
      value=0
      break
    fi

    previous=$selected
    case "$key" in
      "") value=${BH_MENU_KEYS[selected]}; break ;;
      $'\t') selected=$(((selected + 1) % count)) ;;
      $'\e')
        sequence=""
        IFS= read -rsn2 -t 0.15 sequence || true
        case "$sequence" in
          '[A'|'OA') selected=$(((selected - 1 + count) % count)) ;;
          '[B'|'OB') selected=$(((selected + 1) % count)) ;;
          '[C'|'OC') value=${BH_MENU_KEYS[selected]}; break ;;
          '[D'|'OD'|'') value=0; break ;;
        esac
        ;;
      k|K) selected=$(((selected - 1 + count) % count)) ;;
      j|J) selected=$(((selected + 1) % count)) ;;
      *)
        for ((index = 0; index < count; index++)); do
          if [[ "$key" == "${BH_MENU_KEYS[index]}" ]]; then
            value=$key
            break 2
          fi
        done
        ;;
    esac

    if ((selected != previous)); then
      ui_menu_redraw_option "$previous" false "$count"
      ui_menu_redraw_option "$selected" true "$count"
    fi
  done

  printf '\r\033[K\n'
  printf -v "$__name" '%s' "$value"
}
