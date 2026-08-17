#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

nginx_installed() {
  local binary
  binary=$(type -P nginx 2>/dev/null || true)
  [[ -n "$binary" && -x "$binary" ]]
}

nginx_version() {
  local output version
  nginx_installed || return 1
  output=$(nginx -v 2>&1 || true)
  version=$(sed -nE 's|^nginx version:[[:space:]]*nginx/([^[:space:]]+).*$|\1|p' <<<"$output")
  [[ -n "$version" ]] || version=$(sed -nE 's|^nginx version:[[:space:]]*([^[:space:]]+).*$|\1|p' <<<"$output")
  printf '%s' "$version"
}

nginx_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  else
    return 1
  fi
}

nginx_status() {
  local state="off" details="" version=""
  if nginx_installed; then
    state="warn"
    version=$(nginx_version)
    details="${version:+v${version#v} · }usługa zatrzymana"
    if systemctl is-active --quiet nginx 2>/dev/null; then
      state="ok"
      details="${version:+v${version#v} · }systemd: active"
      if ! nginx -t >/dev/null 2>&1; then
        state="warn"
        details="${version:+v${version#v} · }błędna konfiguracja"
      fi
    fi
  fi
  ui_status_row "Nginx" "$state" "$details"
}

nginx_preflight() {
  require_linux || return 1
  require_root || return 1
  require_commands systemctl flock install sed awk || return 1
  NGINX_PACKAGE_MANAGER=$(nginx_package_manager) || {
    ui_error "Nie znaleziono obsługiwanego menedżera pakietów (APT lub DNF)."
    return 1
  }
  if [[ "$NGINX_PACKAGE_MANAGER" == apt ]]; then
    require_commands dpkg-query || return 1
  fi
  ensure_runtime_dirs || return 1
  acquire_operation_lock || return 1
}

nginx_install_impl() {
  local pkg_mgr=${NGINX_PACKAGE_MANAGER:-$(nginx_package_manager 2>/dev/null || printf 'apt')}
  printf 'BlackHost stage: nginx repositories\n'
  case "$pkg_mgr" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update || return 1
      printf 'BlackHost stage: nginx packages\n'
      DEBIAN_FRONTEND=noninteractive apt-get install -y nginx || return 1
      ;;
    dnf)
      printf 'BlackHost stage: nginx packages\n'
      dnf install -y nginx || return 1
      ;;
  esac

  hash -r
  printf 'BlackHost stage: nginx configuration\n'
  nginx -t || return 1
  printf 'BlackHost stage: nginx service\n'
  systemctl enable --now nginx || return 1
  systemctl is-active --quiet nginx || return 1
  printf 'BlackHost stage: nginx complete\n'
}

nginx_install() {
  local version
  nginx_preflight || return 0
  if nginx_installed; then
    version=$(nginx_version)
    ui_warn "Nginx jest już zainstalowany${version:+ (v${version#v})}."
    return 0
  fi

  ui_header "INSTALACJA NGINX"
  ui_section "ZAKRES OPERACJI"
  ui_info "Nginx zostanie zainstalowany z repozytorium systemowego."
  ui_info "Konfiguracja zostanie sprawdzona poleceniem nginx -t."
  ui_warn "CLI nie zmienia reguł firewalla. Wymagane porty otwórz osobno."
  ui_section "PODSUMOWANIE"
  ui_summary_row "Menedżer pakietów" "${NGINX_PACKAGE_MANAGER^^}"
  ui_summary_row "Usługa" "nginx.service"
  ui_summary_row "Konfiguracja" "/etc/nginx"

  ui_confirm "Rozpocząć instalację Nginx?" y || {
    ui_info "Anulowano."
    return 0
  }

  if ! run_with_progress "nginx-install" nginx_install_impl; then
    ui_error "Instalacja Nginx nie została dokończona."
    return 0
  fi

  version=$(nginx_version)
  write_state nginx \
    "package_manager=${NGINX_PACKAGE_MANAGER}" \
    "version=${version}"
  ui_success "Nginx został zainstalowany i uruchomiony."
}

nginx_apt_installed_packages() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' \
    'nginx*' 'libnginx-mod-*' 2>/dev/null \
    | awk '$2 == "ii" { print $1 }' || true
}

nginx_uninstall_impl() {
  local -a nginx_packages=()
  local pkg_mgr=${NGINX_PACKAGE_MANAGER:-$(nginx_package_manager 2>/dev/null || printf 'apt')}
  local remove_config=${NGINX_REMOVE_CONFIG:-false}

  printf 'BlackHost stage: nginx stop\n'
  systemctl disable --now nginx || true

  printf 'BlackHost stage: nginx remove package\n'
  case "$pkg_mgr" in
    apt)
      mapfile -t nginx_packages < <(nginx_apt_installed_packages)
      if ((${#nginx_packages[@]} > 0)); then
        if [[ "$remove_config" == true ]]; then
          DEBIAN_FRONTEND=noninteractive apt-get purge -y "${nginx_packages[@]}" || return 1
        else
          DEBIAN_FRONTEND=noninteractive apt-get remove -y "${nginx_packages[@]}" || return 1
        fi
      fi
      ;;
    dnf)
      dnf remove -y nginx || return 1
      ;;
  esac

  hash -r
  printf 'BlackHost stage: nginx configuration cleanup\n'
  if [[ "$remove_config" == true ]]; then
    rm -rf -- /etc/nginx || return 1
  fi

  if nginx_installed; then
    printf 'Plik wykonywalny Nginx nadal istnieje w systemie.\n' >&2
    return 1
  fi
  printf 'BlackHost stage: nginx uninstall complete\n'
}

nginx_uninstall() {
  local phrase
  nginx_preflight || return 0
  nginx_installed || {
    rm -f "${BLACKHOST_STATE_DIR}/nginx.state"
    ui_info "Nginx nie jest już zainstalowany. Stan BlackHost został uporządkowany."
    return 0
  }

  ui_header "ODINSTALOWANIE NGINX"
  ui_section "ZAKRES OPERACJI"
  ui_warn "Pakiet Nginx i usługa nginx.service zostaną usunięte."
  if pterodactyl_panel_installed; then
    ui_warn "Wykryto Panel Pterodactyl. Usunięcie Nginx może wyłączyć dostęp do panelu."
    ui_confirm "Mimo to kontynuować?" n || {
      ui_info "Anulowano."
      return 0
    }
  fi

  NGINX_REMOVE_CONFIG=false
  ui_confirm "Usunąć również konfigurację /etc/nginx?" n && NGINX_REMOVE_CONFIG=true || true

  ui_section "PODSUMOWANIE"
  ui_summary_row "Pakiety" "Nginx i moduły systemowe"
  ui_summary_row "Konfiguracja" "$([[ "$NGINX_REMOVE_CONFIG" == true ]] && printf 'Usuń' || printf 'Zachowaj')"
  ui_info "/var/www oraz /etc/letsencrypt pozostaną bez zmian."

  ui_prompt phrase "Aby kontynuować, wpisz: USUN NGINX" ""
  [[ "$phrase" == "USUN NGINX" ]] || {
    ui_info "Anulowano."
    return 0
  }

  if ! run_with_progress "nginx-uninstall" nginx_uninstall_impl; then
    ui_error "Odinstalowanie Nginx nie zostało dokończone."
    return 0
  fi

  rm -f "${BLACKHOST_STATE_DIR}/nginx.state"
  ui_success "Nginx został odinstalowany."
}

nginx_menu() {
  local choice version header
  while :; do
    version=$(nginx_version 2>/dev/null || true)
    header="NGINX"
    [[ -n "$version" ]] && header+=" · v${version#v}"
    ui_header "$header"
    ui_section "STAN"
    nginx_status
    ui_section "AKCJE"
    ui_option 1 "Zainstaluj Nginx" "Pakiet systemowy APT/DNF"
    ui_option 2 "Odinstaluj Nginx" "Opcjonalne usunięcie konfiguracji"
    ui_option 0 "Wróć" "Lista programów"
    ui_menu_prompt choice

    case "$choice" in
      1) nginx_install; ui_pause ;;
      2) nginx_uninstall; ui_pause ;;
      0) return 0 ;;
      *) ui_error "Nieprawidłowa opcja."; sleep 1 ;;
    esac
  done
}
