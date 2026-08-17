#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

BLUEPRINT_LATEST_VERSION="beta-2026-06"
BLUEPRINT_LATEST_SHA256="60336dc7362ca922509ab9710a8d64442833920df48a601ce25197cf00ab4a90"
BLUEPRINT_STABLE_VERSION="beta-2026-05"
BLUEPRINT_STABLE_SHA256="d61453bdee5f2aeca252ebae6564de8607055339761e7bdd629ea6b0394c4ac4"
BLUEPRINT_VERSION="$BLUEPRINT_STABLE_VERSION"
BLUEPRINT_SHA256="$BLUEPRINT_STABLE_SHA256"
BLUEPRINT_URL="https://github.com/BlueprintFramework/framework/releases/download/${BLUEPRINT_VERSION}/release.zip"
BLUEPRINT_PANEL_DIR="/var/www/pterodactyl"

blueprint_use_release() {
  local version=$1 sha256
  if (($# >= 2)); then
    sha256=$2
  elif [[ "$version" == "$BLUEPRINT_LATEST_VERSION" ]]; then
    sha256="$BLUEPRINT_LATEST_SHA256"
  elif [[ "$version" == "$BLUEPRINT_STABLE_VERSION" ]]; then
    sha256="$BLUEPRINT_STABLE_SHA256"
  else
    return 1
  fi
  BLUEPRINT_VERSION=$version
  BLUEPRINT_SHA256=$sha256
  BLUEPRINT_URL="https://github.com/BlueprintFramework/framework/releases/download/${BLUEPRINT_VERSION}/release.zip"
}

blueprint_select_release() {
  local choice
  while :; do
    ui_header "BLUEPRINT / WYDANIE"
    ui_section "DOSTĘPNE WERSJE"
    ui_option 1 "Najnowsza stabilna" "${BLUEPRINT_STABLE_VERSION} · Supported · zalecana"
    ui_option 2 "Najnowsza wersja" "${BLUEPRINT_LATEST_VERSION} · Latest"
    ui_option 0 "Wróć" "Anuluj instalację"
    ui_menu_prompt choice

    case "$choice" in
      1)
        blueprint_use_release "$BLUEPRINT_STABLE_VERSION" "$BLUEPRINT_STABLE_SHA256"
        return 0
        ;;
      2)
        blueprint_use_release "$BLUEPRINT_LATEST_VERSION" "$BLUEPRINT_LATEST_SHA256"
        return 0
        ;;
      0) return 1 ;;
      *) ui_error "Nieprawidłowa opcja."; sleep 1 ;;
    esac
  done
}

blueprint_installed() {
  [[ -f "${BLUEPRINT_PANEL_DIR}/.blueprint/extensions/blueprint/private/db/is_installed" ]]
}

blueprint_files_present() {
  [[ -f "${BLUEPRINT_PANEL_DIR}/blueprint.sh" || -d "${BLUEPRINT_PANEL_DIR}/.blueprint" ]]
}

blueprint_status() {
  local state="off" details="" version_file state_file
  version_file="${BLUEPRINT_PANEL_DIR}/.blueprint/extensions/blueprint/private/db/version"
  state_file="${BLACKHOST_STATE_DIR}/blueprint.state"
  if blueprint_installed; then
    state="ok"
    details="zainstalowany"
    if [[ -s "$version_file" ]]; then
      details=$(head -n 1 "$version_file" 2>/dev/null || printf 'zainstalowany')
    elif [[ -r "$state_file" ]]; then
      details=$(sed -n 's/^version=//p' "$state_file" 2>/dev/null | head -n 1)
      details=${details:-zainstalowany}
    fi
  elif blueprint_files_present; then
    state="warn"
    details="instalacja niepełna"
  fi
  ui_status_row "Blueprint" "$state" "$details"
}

blueprint_detect_webuser() {
  local owner candidate
  owner=$(stat -c '%U' "${BLUEPRINT_PANEL_DIR}/storage" 2>/dev/null || true)
  if [[ -n "$owner" && "$owner" != root ]] && id "$owner" >/dev/null 2>&1; then
    printf '%s' "$owner"
    return 0
  fi
  for candidate in www-data nginx apache; do
    if id "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

blueprint_preflight() {
  require_linux || return 1
  require_root || return 1
  command -v apt-get >/dev/null 2>&1 || {
    ui_error "Instalator Blueprinta obsługuje obecnie Debian/Ubuntu z menedżerem APT."
    return 1
  }
  require_commands curl sha256sum stat id php flock install awk sed mktemp bash chmod || return 1
  pterodactyl_panel_installed || {
    ui_error "Blueprint wymaga wcześniej zainstalowanego Panelu Pterodactyl."
    return 1
  }
  [[ -f "${BLUEPRINT_PANEL_DIR}/.env" ]] || {
    ui_error "Nie znaleziono pliku .env Panelu Pterodactyl."
    return 1
  }
  php "${BLUEPRINT_PANEL_DIR}/artisan" --version >/dev/null 2>&1 || {
    ui_error "Polecenie Artisan Panelu nie działa. Najpierw napraw instalację panelu."
    return 1
  }
  BLUEPRINT_WEBUSER=$(blueprint_detect_webuser) || {
    ui_error "Nie udało się wykryć użytkownika serwera WWW."
    return 1
  }
  BLUEPRINT_WEBGROUP=$(id -gn "$BLUEPRINT_WEBUSER" 2>/dev/null) || return 1
  ensure_runtime_dirs || return 1
  acquire_operation_lock || return 1
}

blueprint_install_dependencies() {
  local node_major=0 key_file
  DEBIAN_FRONTEND=noninteractive apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl git gnupg unzip wget zip || return 1
  command -v gpg >/dev/null 2>&1 || return 1
  command -v unzip >/dev/null 2>&1 || return 1

  if command -v node >/dev/null 2>&1; then
    node_major=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || printf '0')
    [[ "$node_major" =~ ^[0-9]+$ ]] || node_major=0
  fi
  if ((node_major < 22)); then
    printf 'BlackHost stage: blueprint node repository\n'
    install -d -m 755 /etc/apt/keyrings || return 1
    key_file=$(mktemp /tmp/blackhost-nodesource-key.XXXXXX)
    if ! curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      --output "$key_file" https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key; then
      rm -f -- "$key_file"
      return 1
    fi
    if ! gpg --dearmor --batch --yes --output /etc/apt/keyrings/nodesource.gpg "$key_file"; then
      rm -f -- "$key_file"
      return 1
    fi
    rm -f -- "$key_file"
    printf '%s\n' \
      'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' \
      >/etc/apt/sources.list.d/nodesource.list
    apt-get update || return 1
    printf 'BlackHost stage: blueprint node install\n'
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs || return 1
  fi

  node_major=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || printf '0')
  [[ "$node_major" =~ ^[0-9]+$ ]] && ((node_major >= 22)) || return 1
  command -v npm >/dev/null 2>&1 || return 1
  printf 'BlackHost stage: blueprint yarn\n'
  npm install --global yarn || return 1
}

blueprint_write_config() {
  local config_file="${BLUEPRINT_PANEL_DIR}/.blueprintrc"
  if [[ ! -f "$config_file" ]]; then
    printf 'WEBUSER="%s";\nOWNERSHIP="%s:%s";\nUSERSHELL="/bin/bash";\n' \
      "$BLUEPRINT_WEBUSER" "$BLUEPRINT_WEBUSER" "$BLUEPRINT_WEBGROUP" \
      >"$config_file" || return 1
  fi
}

blueprint_install_impl() {
  local archive installer_status
  printf 'BlackHost stage: blueprint dependencies\n'
  blueprint_install_dependencies || return 1

  archive=$(mktemp /tmp/blackhost-blueprint-release.XXXXXX)
  printf 'BlackHost stage: blueprint download\n'
  if ! curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --output "$archive" "$BLUEPRINT_URL"; then
    rm -f -- "$archive"
    return 1
  fi

  printf 'BlackHost stage: blueprint verify\n'
  if [[ "$(sha256sum "$archive" | awk '{print tolower($1)}')" != "$BLUEPRINT_SHA256" ]]; then
    printf 'Suma SHA-256 Blueprinta jest inna niż oczekiwana.\n' >&2
    rm -f -- "$archive"
    return 1
  fi

  printf 'BlackHost stage: blueprint extract\n'
  unzip -o "$archive" -d "$BLUEPRINT_PANEL_DIR" || {
    rm -f -- "$archive"
    return 1
  }
  rm -f -- "$archive"

  printf 'BlackHost stage: blueprint configure\n'
  blueprint_write_config || return 1
  chmod +x "${BLUEPRINT_PANEL_DIR}/blueprint.sh" || return 1

  printf 'BlackHost stage: blueprint framework\n'
  installer_status=0
  printf '\n' | bash "${BLUEPRINT_PANEL_DIR}/blueprint.sh" || installer_status=$?
  if ((installer_status != 0)); then
    (cd "$BLUEPRINT_PANEL_DIR" && php artisan up) || true
    return "$installer_status"
  fi

  hash -r
  blueprint_installed || return 1
  [[ -x "$(type -P blueprint 2>/dev/null || true)" ]] || return 1
  printf 'BlackHost stage: blueprint complete\n'
}

blueprint_install() {
  blueprint_preflight || return 0
  if blueprint_installed; then
    ui_warn "Blueprint jest już zainstalowany."
    return 0
  fi
  blueprint_select_release || return 0

  ui_header "INSTALACJA BLUEPRINT"
  ui_section "ZAKRES OPERACJI"
  ui_info "Zostanie zainstalowany Blueprint Framework ${BLUEPRINT_VERSION}."
  ui_info "Instalator doda Node.js 22, Yarn i wymagane pakiety, jeżeli ich brakuje."
  ui_warn "Blueprint modyfikuje pliki Panelu Pterodactyl i przebudowuje jego frontend."
  ui_info "Podczas instalacji panel zostanie na chwilę przełączony w tryb konserwacji."
  if blueprint_files_present; then
    ui_warn "Wykryto pliki niedokończonej instalacji. Instalator spróbuje ją dokończyć."
  fi

  ui_section "PODSUMOWANIE"
  ui_summary_row "Wydanie" "$BLUEPRINT_VERSION"
  ui_summary_row "Panel" "$BLUEPRINT_PANEL_DIR"

  ui_confirm "Rozpocząć instalację Blueprinta?" y || {
    ui_info "Anulowano."
    return 0
  }

  if ! run_with_progress "blueprint-install" blueprint_install_impl; then
    ui_error "Instalacja Blueprinta nie została dokończona."
    return 0
  fi

  write_state blueprint \
    "version=${BLUEPRINT_VERSION}" \
    "panel_dir=${BLUEPRINT_PANEL_DIR}"
  ui_success "Blueprint ${BLUEPRINT_VERSION} został zainstalowany."
  ui_info "Polecenie zarządzania rozszerzeniami: blueprint"
}

blueprint_uninstall_impl() {
  printf 'BlackHost stage: blueprint uninstall preflight\n'
  pterodactyl_update_runtime_preflight false || return 1
  require_commands find rm || return 1
  PTERO_UPDATE_HAS_BLUEPRINT=false
  PTERO_UPDATE_CLEAN_PANEL_FILES=true
  PTERO_UPDATE_REMOVE_BLUEPRINT=true
  PTERO_UPDATE_ARCHIVE_URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
  pterodactyl_update_panel_impl
}

blueprint_uninstall() {
  local new_panel_version phrase
  ui_header "USUWANIE BLUEPRINT"
  blueprint_installed || {
    ui_error "Nie wykryto zainstalowanego Blueprinta."
    return 0
  }

  ui_section "ZAKRES OPERACJI"
  ui_warn "Blueprint i wszystkie zainstalowane rozszerzenia zostaną usunięte."
  ui_warn "Zmodyfikowane pliki Panelu zostaną zastąpione czystym najnowszym wydaniem Pterodactyla."
  ui_info "Plik .env i baza danych Panelu zostaną zachowane."
  ui_warn "Własne zmiany w plikach Panelu zostaną utracone."
  ui_prompt phrase "Aby kontynuować, wpisz: USUN BLUEPRINT" ""
  [[ "$phrase" == "USUN BLUEPRINT" ]] || {
    ui_info "Anulowano."
    return 0
  }

  if ! run_with_progress "blueprint-uninstall" blueprint_uninstall_impl; then
    ui_error "Odinstalowanie Blueprinta nie zostało dokończone. Sprawdź pełny log operacji."
    return 0
  fi

  if blueprint_files_present || [[ -e "${BLUEPRINT_PANEL_DIR}/.blueprintrc" || -e /usr/local/bin/blueprint ]]; then
    ui_error "Część plików Blueprinta nadal istnieje. Sprawdź pełny log operacji."
    return 0
  fi
  rm -f -- "${BLACKHOST_STATE_DIR}/blueprint.state"
  new_panel_version=$(pterodactyl_panel_version)
  ui_success "Blueprint został odinstalowany, a czysty Panel${new_panel_version:+ v${new_panel_version#v}} został odtworzony."
}
