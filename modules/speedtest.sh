#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

SPEEDTEST_DEB_REPO_SCRIPT="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
SPEEDTEST_RPM_REPO_SCRIPT="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"

speedtest_remove_temp_dir() {
  local target=$1
  case "$target" in
    /tmp/blackhost-speedtest.*)
      [[ -d "$target" ]] && rm -rf -- "$target"
      ;;
    *)
      ui_error "Odmowa usunięcia nieoczekiwanej ścieżki tymczasowej: $target"
      return 1
      ;;
  esac
}

speedtest_official_available() {
  command -v speedtest >/dev/null 2>&1 \
    && speedtest --version 2>&1 | grep -qi 'Ookla'
}

speedtest_install_package_impl() {
  local repo_script="${SPEEDTEST_TEMP_DIR}/ookla-repository.sh"

  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      >"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates \
      >>"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --output "$repo_script" "$SPEEDTEST_DEB_REPO_SCRIPT" \
      >>"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    bash "$repo_script" >>"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq speedtest \
      >>"$SPEEDTEST_INSTALL_LOG" 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl ca-certificates \
      >"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --output "$repo_script" "$SPEEDTEST_RPM_REPO_SCRIPT" \
      >>"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    bash "$repo_script" >>"$SPEEDTEST_INSTALL_LOG" 2>&1 || return 1
    dnf install -y -q speedtest >>"$SPEEDTEST_INSTALL_LOG" 2>&1
  else
    printf 'Brak obsługiwanego menedżera pakietów (apt-get lub dnf).\n' \
      >"$SPEEDTEST_INSTALL_LOG"
    return 1
  fi
}

speedtest_ensure_package() {
  speedtest_official_available && return 0

  if command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1; then
    ui_error "Wykryto nieoficjalny speedtest-cli, który koliduje z pakietem Ookli."
    ui_info "BlackHost nie usunie go automatycznie. Usuń konflikt ręcznie i ponów instalację."
    return 1
  fi

  ui_warn "Oficjalny pakiet speedtest firmy Ookla nie jest zainstalowany."
  ui_confirm "Dodać repozytorium Ookli i zainstalować pakiet speedtest?" y || return 1
  require_root || return 1

  if ! run_with_spinner "Instalowanie oficjalnego pakietu speedtest" speedtest_install_package_impl; then
    ui_error "Nie udało się zainstalować oficjalnego pakietu speedtest."
    show_log_excerpt "$SPEEDTEST_INSTALL_LOG"
    return 1
  fi

  speedtest_official_available || {
    ui_error "Instalacja zakończyła się, ale oficjalne polecenie speedtest jest niedostępne."
    return 1
  }
  ui_success "Oficjalny pakiet speedtest firmy Ookla został zainstalowany."
}

speedtest_measure() {
  speedtest --accept-license --accept-gdpr --progress=no \
    >"$SPEEDTEST_RESULT_FILE" 2>"$SPEEDTEST_ERROR_FILE"
}

speedtest_parse_server() {
  awk '/^[[:space:]]*Server:/ {
    sub(/^[[:space:]]*Server:[[:space:]]*/, "")
    sub(/[[:space:]]+\(id:[[:space:]]*[0-9]+\).*$/, "")
    print
    exit
  }' "$1"
}

speedtest_run() {
  local temp_dir server ping download upload result_url
  require_linux || return 0
  require_commands awk grep mktemp || return 0

  ui_header "SPEEDTEST"
  ui_section "TEST ŁĄCZA"
  ui_info "Pomiar wykorzystuje oficjalny pakiet Speedtest CLI firmy Ookla."
  ui_confirm "Rozpocząć speedtest?" y || {
    ui_info "Anulowano."
    return 0
  }

  temp_dir=$(mktemp -d /tmp/blackhost-speedtest.XXXXXX) || {
    ui_error "Nie udało się utworzyć katalogu tymczasowego."
    return 0
  }
  SPEEDTEST_TEMP_DIR=$temp_dir
  SPEEDTEST_INSTALL_LOG="${temp_dir}/install.log"
  SPEEDTEST_RESULT_FILE="${temp_dir}/result.log"
  SPEEDTEST_ERROR_FILE="${temp_dir}/error.log"
  export SPEEDTEST_TEMP_DIR SPEEDTEST_INSTALL_LOG SPEEDTEST_RESULT_FILE SPEEDTEST_ERROR_FILE

  if ! speedtest_ensure_package; then
    speedtest_remove_temp_dir "$temp_dir"
    return 0
  fi

  printf '\n'
  if ! run_with_spinner "Ookla mierzy ping, pobieranie i wysyłanie" speedtest_measure; then
    ui_error "Speedtest nie został ukończony."
    if [[ -s "$SPEEDTEST_ERROR_FILE" ]]; then
      show_log_excerpt "$SPEEDTEST_ERROR_FILE"
    fi
    speedtest_remove_temp_dir "$temp_dir"
    return 0
  fi

  server=$(speedtest_parse_server "$SPEEDTEST_RESULT_FILE")
  ping=$(awk -F ': ' '/^[[:space:]]*(Idle )?Latency:/ { split($2, value, " "); print value[1] " " value[2]; exit }' "$SPEEDTEST_RESULT_FILE")
  download=$(awk -F ': ' '/^[[:space:]]*Download:/ { split($2, value, " "); print value[1] " " value[2]; exit }' "$SPEEDTEST_RESULT_FILE")
  upload=$(awk -F ': ' '/^[[:space:]]*Upload:/ { split($2, value, " "); print value[1] " " value[2]; exit }' "$SPEEDTEST_RESULT_FILE")
  result_url=$(awk '/^[[:space:]]*Result URL:/ { sub(/^[[:space:]]*Result URL:[[:space:]]*/, ""); print; exit }' "$SPEEDTEST_RESULT_FILE")

  if [[ -z "$ping" || -z "$download" || -z "$upload" ]]; then
    ui_error "Pakiet speedtest zwrócił wynik w nieznanym formacie."
    show_log_excerpt "$SPEEDTEST_RESULT_FILE"
    speedtest_remove_temp_dir "$temp_dir"
    return 0
  fi

  speedtest_remove_temp_dir "$temp_dir"
  ui_section "WYNIK"
  [[ -n "$server" ]] && ui_key_value "SERWER" "$server"

  printf '\n'
  ui_three_columns "$BH_MUTED" "PING" "POBIERANIE" "WYSYŁANIE"
  ui_three_columns "$BH_WHITE" "$ping" "$download" "$upload"
  if [[ -n "$result_url" ]]; then
    ui_section "WYNIK ONLINE"
    ui_hyperlink "$result_url"
  fi
}
