#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

PTERO_INSTALLER_VERSION="v1.3.0"
PTERO_INSTALLER_SHA256="1611f0f3180c5449cfa2437fd22e0f13d082ab39cf749aa882193f831f8fc77c"
PTERO_INSTALLER_URL="https://github.com/pterodactyl-installer/pterodactyl-installer/archive/refs/tags/${PTERO_INSTALLER_VERSION}.tar.gz"

pterodactyl_panel_installed() {
  [[ -d /var/www/pterodactyl && -f /var/www/pterodactyl/artisan ]]
}

pterodactyl_wings_installed() {
  [[ -x /usr/local/bin/wings || -f /etc/systemd/system/wings.service ]]
}

pterodactyl_release_version_from_url() {
  local version=${1%/}
  version=${version##*/}
  version=${version%%\?*}
  version=${version%%#*}
  version=${version#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || return 1
  printf '%s' "$version"
}

pterodactyl_latest_release_version() {
  local repository=$1 effective_url version
  effective_url=$(curl --fail --location --silent --show-error --head \
    --connect-timeout 10 --max-time 25 --proto '=https' --tlsv1.2 \
    --output /dev/null --write-out '%{url_effective}' \
    "https://github.com/pterodactyl/${repository}/releases/latest") || return 1
  version=$(pterodactyl_release_version_from_url "$effective_url") || return 1
  printf '%s' "$version"
}

pterodactyl_wings_version() {
  local binary=${1:-/usr/local/bin/wings} argument output version
  [[ -x "$binary" ]] || return 1
  for argument in version --version -v; do
    output=$("$binary" "$argument" 2>&1 || true)
    version=$(grep -Eo '[vV]?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*' \
      <<<"$output" | head -n 1)
    if [[ -n "$version" ]]; then
      version=${version#v}
      version=${version#V}
      printf '%s' "$version"
      return 0
    fi
  done
  return 1
}

pterodactyl_wings_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

pterodactyl_panel_info() {
  pterodactyl_panel_installed || return 1
  command -v php >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    (cd /var/www/pterodactyl && timeout 10s php artisan p:info --no-ansi 2>/dev/null) || return 1
  else
    (cd /var/www/pterodactyl && php artisan p:info --no-ansi 2>/dev/null) || return 1
  fi
}

pterodactyl_panel_info_value() {
  local label=$1 info
  if (($# >= 2)); then
    info=$2
  else
    info=$(pterodactyl_panel_info) || return 1
  fi

  awk -F'|' -v wanted="$label" '
    {
      for (field = 1; field <= NF; field++) {
        value = $field
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value == wanted && field < NF) {
          result = $(field + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", result)
          print result
          exit
        }
      }
    }
  ' <<<"$info"
}

pterodactyl_panel_version() {
  local version=""
  if pterodactyl_panel_installed; then
    if [[ -r /var/www/pterodactyl/config/app.php ]]; then
      version=$(sed -nE "s/.*'version'[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/p" \
        /var/www/pterodactyl/config/app.php | head -n 1)
    fi
    [[ -n "$version" ]] || version=$(pterodactyl_panel_info_value "Panel Version" 2>/dev/null || true)
  fi
  printf '%s' "$version"
}

pterodactyl_panel_healthy() {
  local app_url fqdn
  pterodactyl_panel_installed || return 1
  crontab -l 2>/dev/null | grep -qF '/var/www/pterodactyl/artisan schedule:run' || return 1
  systemctl is-active --quiet pteroq 2>/dev/null || return 1
  [[ -f /etc/nginx/sites-available/pterodactyl.conf || -f /etc/nginx/conf.d/pterodactyl.conf ]] || return 1
  nginx -t >/dev/null 2>&1 || return 1

  app_url=$(grep -m1 '^APP_URL=' /var/www/pterodactyl/.env 2>/dev/null || true)
  app_url=${app_url#APP_URL=}
  app_url=${app_url#\"}
  app_url=${app_url%\"}
  if [[ "$app_url" == https://* ]]; then
    fqdn=${app_url#https://}
    fqdn=${fqdn%%/*}
    [[ -d "/etc/letsencrypt/live/${fqdn}" ]] || return 1
  fi
}

pterodactyl_status() {
  local panel_version=${1:-} wings_version="" wings_state="off" wings_details=""
  [[ -n "$panel_version" ]] || panel_version=$(pterodactyl_panel_version)
  if pterodactyl_panel_healthy; then
    ui_status_row "Pterodactyl Panel" ok "${panel_version:+v${panel_version#v}}"
  elif pterodactyl_panel_installed; then
    ui_status_row "Pterodactyl Panel" warn "${panel_version:+v${panel_version#v} · }instalacja niepełna"
  else
    ui_status_row "Pterodactyl Panel" off
  fi

  if pterodactyl_wings_installed; then
    wings_version=$(pterodactyl_wings_version 2>/dev/null || true)
    wings_state="warn"
    wings_details="${wings_version:+v${wings_version#v} · }usługa zatrzymana"
    if systemctl is-active --quiet wings 2>/dev/null; then
      wings_state="ok"
      wings_details="${wings_version:+v${wings_version#v} · }systemd: active"
    fi
  fi
  ui_status_row "Pterodactyl Wings" "$wings_state" "$wings_details"
}

pterodactyl_preflight() {
  require_linux
  require_root
  require_commands curl sha256sum tar tee flock install
  ensure_runtime_dirs
  acquire_operation_lock
}

pterodactyl_fetch_upstream() {
  local temp_dir archive actual_hash extracted
  temp_dir=$(mktemp -d /tmp/blackhost-pterodactyl.XXXXXX)
  archive="${temp_dir}/upstream.tar.gz"

  if ! run_with_spinner "Pobieranie pterodactyl-installer ${PTERO_INSTALLER_VERSION}" \
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      --output "$archive" "$PTERO_INSTALLER_URL"; then
    ui_error "Nie udało się pobrać instalatora Pterodactyla."
    pterodactyl_remove_temp_dir "$temp_dir"
    return 1
  fi

  actual_hash=$(sha256sum "$archive" | awk '{print tolower($1)}')
  if [[ "$actual_hash" != "$PTERO_INSTALLER_SHA256" ]]; then
    ui_error "Suma SHA-256 instalatora jest inna niż oczekiwana. Instalacja przerwana."
    pterodactyl_remove_temp_dir "$temp_dir"
    return 1
  fi

  tar -xzf "$archive" -C "$temp_dir"
  extracted="${temp_dir}/pterodactyl-installer-${PTERO_INSTALLER_VERSION#v}"
  [[ -f "${extracted}/lib/lib.sh" ]] || {
    ui_error "Pobrane archiwum nie ma oczekiwanej struktury."
    pterodactyl_remove_temp_dir "$temp_dir"
    return 1
  }

  sed -i \
    's/certbot --nginx --redirect --no-eff-email/certbot --nginx --redirect --non-interactive --agree-tos --no-eff-email/' \
    "${extracted}/installers/panel.sh"
  sed -i \
    's/certbot certonly --no-eff-email/certbot certonly --non-interactive --agree-tos --no-eff-email/' \
    "${extracted}/installers/wings.sh"
  if ! grep -q -- '--agree-tos' "${extracted}/installers/panel.sh" \
    || ! grep -q -- '--agree-tos' "${extracted}/installers/wings.sh"; then
    ui_error "Nie udało się przygotować bezobsługowej konfiguracji Let's Encrypt."
    pterodactyl_remove_temp_dir "$temp_dir"
    return 1
  fi

  PTERO_SOURCE_DIR=$extracted
  PTERO_TEMP_DIR=$temp_dir
  ui_success "Instalator Pterodactyla jest gotowy."
}

pterodactyl_remove_temp_dir() {
  local target=$1
  case "$target" in
    /tmp/blackhost-pterodactyl.*)
      [[ -d "$target" ]] && rm -rf -- "$target"
      ;;
    *)
      ui_error "Odmowa usunięcia nieoczekiwanej ścieżki tymczasowej: $target"
      return 1
      ;;
  esac
}

pterodactyl_cleanup_upstream() {
  if [[ -n "${PTERO_TEMP_DIR:-}" && -d "$PTERO_TEMP_DIR" ]]; then
    pterodactyl_remove_temp_dir "$PTERO_TEMP_DIR"
  fi
}

pterodactyl_prepare_managed_uninstaller() {
  local uninstall_script="${PTERO_SOURCE_DIR}/installers/uninstall.sh"
  [[ -f "$uninstall_script" ]] || {
    ui_error "Pobrany pterodactyl-installer nie zawiera modułu odinstalowania."
    return 1
  }

  # Funkcja rm_database nadal należy do upstreamu. Dodana gałąź pozwala jedynie
  # przekazać decyzje z polskiego interfejsu bez oczekiwania na angielskie read.
  sed -i '/^rm_database() {/a\
  if [[ "${BLACKHOST_DATABASE_MODE:-}" == "managed" ]]; then\
    output "Removing database..."\
    if [[ "${BLACKHOST_REMOVE_DATABASE:-false}" == true ]]; then\
      mariadb -u root -e "DROP DATABASE \`$DATABASE\`;" 2>/dev/null || warning "Failed to drop database $DATABASE."\
    else\
      output "Database removal skipped."\
    fi\
    output "Removing database user..."\
    if [[ "${BLACKHOST_REMOVE_DB_USER:-false}" == true ]]; then\
      mariadb -u root -e "DROP USER '\''$DB_USER'\''@'\''127.0.0.1'\'';" 2>/dev/null || warning "Failed to drop user $DB_USER."\
    else\
      output "Database user removal skipped."\
    fi\
    mariadb -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true\
    success "Handled database and database user."\
    return 0\
  fi' "$uninstall_script"

  grep -qF 'BLACKHOST_DATABASE_MODE' "$uninstall_script" || {
    ui_error "Nie udało się podłączyć polskich pytań do uninstallera."
    return 1
  }
}

pterodactyl_read_panel_env_value() {
  local key=$1 fallback=$2 value=""
  if [[ -r /var/www/pterodactyl/.env ]]; then
    value=$(grep -m1 "^${key}=" /var/www/pterodactyl/.env 2>/dev/null || true)
    value=${value#*=}
    value=${value#\"}
    value=${value%\"}
  fi
  printf '%s' "${value:-$fallback}"
}

pterodactyl_run_upstream() {
  local component=$1
  export GITHUB_SOURCE="$PTERO_INSTALLER_VERSION"
  export SCRIPT_RELEASE="$PTERO_INSTALLER_VERSION"
  export GITHUB_BASE_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer"

  # Osobny proces Bash zachowuje `set -e` upstreamu nawet wtedy, gdy wynik tej
  # funkcji jest sprawdzany przez menu BlackHost.
  bash -Ee -c 'source "$1"; source "$2"' blackhost-upstream \
    "${PTERO_SOURCE_DIR}/lib/lib.sh" \
    "${PTERO_SOURCE_DIR}/installers/${component}.sh"
}

pterodactyl_prompt_panel() {
  ui_header "INSTALACJA PANELU"
  ui_section "KONFIGURACJA"
  ui_info "Podaj parametry nowej instalacji Pterodactyl Panel."

  while :; do
    ui_prompt PTERO_FQDN "Domena panelu" "panel.example.com"
    valid_fqdn "$PTERO_FQDN" && break
    ui_error "Podaj pełną domenę, np. panel.example.com."
  done

  while :; do
    ui_prompt PTERO_EMAIL "E-mail techniczny / Let's Encrypt" "admin@example.pl"
    valid_email "$PTERO_EMAIL" && break
    ui_error "Nieprawidłowy adres e-mail."
  done

  while :; do
    ui_prompt PTERO_ADMIN_EMAIL "E-mail pierwszego administratora" "$PTERO_EMAIL"
    valid_email "$PTERO_ADMIN_EMAIL" && break
    ui_error "Nieprawidłowy adres e-mail."
  done

  ui_prompt PTERO_ADMIN_USERNAME "Login administratora" "admin"
  ui_prompt PTERO_ADMIN_FIRSTNAME "Imię administratora" "Admin"
  ui_prompt PTERO_ADMIN_LASTNAME "Nazwisko administratora" "Admin"

  ui_secret PTERO_ADMIN_PASSWORD "Hasło administratora" "Wygenerowane"
  if [[ -z "$PTERO_ADMIN_PASSWORD" ]]; then
    PTERO_ADMIN_PASSWORD=$(random_secret)
    PTERO_ADMIN_PASSWORD_MODE="automatyczne"
  else
    PTERO_ADMIN_PASSWORD_MODE="własne"
  fi

  while :; do
    ui_prompt PTERO_DB_NAME "Nazwa bazy danych" "panel"
    valid_db_identifier "$PTERO_DB_NAME" && break
    ui_error "Dozwolone są litery, cyfry i znak _."
  done

  while :; do
    ui_prompt PTERO_DB_USER "Użytkownik bazy danych" "pterodactyl"
    valid_db_identifier "$PTERO_DB_USER" && break
    ui_error "Dozwolone są litery, cyfry i znak _."
  done

  ui_prompt PTERO_TIMEZONE "Strefa czasowa" "Europe/Warsaw"
  valid_timezone "$PTERO_TIMEZONE" || {
    ui_error "Nieznana strefa czasowa: $PTERO_TIMEZONE"
    return 1
  }

  ui_secret PTERO_DB_PASSWORD "Hasło użytkownika bazy" "Wygenerowane"
  if [[ -z "$PTERO_DB_PASSWORD" ]]; then
    PTERO_DB_PASSWORD=$(random_secret)
    PTERO_DB_PASSWORD_MODE="automatyczne"
  else
    PTERO_DB_PASSWORD_MODE="własne"
  fi
  ui_confirm "Skonfigurować firewall UFW? Niezalecane, jeżeli korzystasz z firewalla panelowego" n && PTERO_FIREWALL=true || PTERO_FIREWALL=false
  ui_confirm "Pobrać certyfikat HTTPS z Let's Encrypt?" y && PTERO_LETSENCRYPT=true || PTERO_LETSENCRYPT=false
  if [[ "$PTERO_LETSENCRYPT" == true ]]; then
    ui_warn "Let's Encrypt wymaga otwartego z internetu portu TCP 80."
    ui_confirm "Akceptujesz warunki usługi Let's Encrypt?" y || PTERO_LETSENCRYPT=false
  fi
  PTERO_ASSUME_SSL=false
  if [[ "$PTERO_LETSENCRYPT" == false ]]; then
    ui_confirm "Skonfigurować Nginx pod istniejący certyfikat SSL?" n && PTERO_ASSUME_SSL=true || true
  fi
  ui_confirm "Włączyć anonimową telemetrię Pterodactyla?" n && PTERO_TELEMETRY=true || PTERO_TELEMETRY=false

  local admin_password_summary db_password_summary https_summary
  if [[ "$PTERO_ADMIN_PASSWORD_MODE" == "automatyczne" ]]; then
    admin_password_summary="$PTERO_ADMIN_PASSWORD (wygenerowane)"
  else
    admin_password_summary="Własne (ukryte)"
  fi
  if [[ "$PTERO_DB_PASSWORD_MODE" == "automatyczne" ]]; then
    db_password_summary="$PTERO_DB_PASSWORD (wygenerowane)"
  else
    db_password_summary="Własne (ukryte)"
  fi
  if [[ "$PTERO_LETSENCRYPT" == true ]]; then
    https_summary="${BH_GREEN}Let's Encrypt${BH_RESET}"
  elif [[ "$PTERO_ASSUME_SSL" == true ]]; then
    https_summary="Istniejący certyfikat"
  else
    https_summary="${BH_MUTED}Wyłączony${BH_RESET}"
  fi

  ui_section "PODSUMOWANIE INSTALACJI"
  ui_summary_group "PANEL"
  ui_summary_row "Domena" "$PTERO_FQDN"
  ui_summary_row "E-mail techniczny" "$PTERO_EMAIL"

  ui_summary_group "ADMINISTRATOR"
  ui_summary_row "E-mail" "$PTERO_ADMIN_EMAIL"
  ui_summary_row "Login" "$PTERO_ADMIN_USERNAME"
  ui_summary_row "Imię i nazwisko" "$PTERO_ADMIN_FIRSTNAME $PTERO_ADMIN_LASTNAME"
  ui_summary_row "Hasło" "$admin_password_summary"

  ui_summary_group "BAZA DANYCH"
  ui_summary_row "Nazwa" "$PTERO_DB_NAME"
  ui_summary_row "Użytkownik" "$PTERO_DB_USER"
  ui_summary_row "Hasło" "$db_password_summary"

  ui_summary_group "USTAWIENIA"
  ui_summary_row "Strefa czasowa" "$PTERO_TIMEZONE"
  ui_summary_row "Firewall UFW" "$(ui_state_value "$PTERO_FIREWALL")"
  ui_summary_row "HTTPS" "$https_summary"
  ui_summary_row "Telemetria" "$(ui_state_value "$PTERO_TELEMETRY" 'Włączona' 'Wyłączona')"
  if [[ "$PTERO_ADMIN_PASSWORD_MODE" == "automatyczne" || "$PTERO_DB_PASSWORD_MODE" == "automatyczne" ]]; then
    printf '\n'
    ui_warn "Zapisz wygenerowane hasła przed rozpoczęciem instalacji."
  fi
  ui_confirm "Rozpocząć instalację?" y
}

pterodactyl_install_panel_impl() {
  export FQDN="$PTERO_FQDN"
  export MYSQL_DB="$PTERO_DB_NAME"
  export MYSQL_USER="$PTERO_DB_USER"
  export MYSQL_PASSWORD="$PTERO_DB_PASSWORD"
  export timezone="$PTERO_TIMEZONE"
  export email="$PTERO_EMAIL"
  export telemetry="$PTERO_TELEMETRY"
  export user_email="$PTERO_ADMIN_EMAIL"
  export user_username="$PTERO_ADMIN_USERNAME"
  export user_firstname="$PTERO_ADMIN_FIRSTNAME"
  export user_lastname="$PTERO_ADMIN_LASTNAME"
  export user_password="$PTERO_ADMIN_PASSWORD"
  export ASSUME_SSL="$PTERO_ASSUME_SSL"
  export CONFIGURE_LETSENCRYPT="$PTERO_LETSENCRYPT"
  export CONFIGURE_FIREWALL="$PTERO_FIREWALL"

  pterodactyl_run_upstream panel
}

pterodactyl_install_panel() {
  PTERO_ACTION_COMPLETED=false
  pterodactyl_preflight || return 0
  if pterodactyl_panel_installed; then
    if pterodactyl_panel_healthy; then
      ui_error "Panel Pterodactyl jest już zainstalowany."
    else
      ui_warn "Wykryto niedokończoną instalację. Wybierz opcję „Dokończ / napraw Panel”."
    fi
    return 0
  fi
  pterodactyl_prompt_panel || return 0
  pterodactyl_fetch_upstream || return 0

  if ! run_with_progress "pterodactyl-panel-install" pterodactyl_install_panel_impl; then
    pterodactyl_cleanup_upstream
    ui_error "Instalacja panelu nie została dokończona."
    return 0
  fi
  pterodactyl_cleanup_upstream
  write_state pterodactyl-panel \
    "upstream_version=${PTERO_INSTALLER_VERSION}" \
    "fqdn=${PTERO_FQDN}" \
    "database=${PTERO_DB_NAME}" \
    "database_user=${PTERO_DB_USER}"
  PTERO_ACTION_COMPLETED=true
  ui_success "Panel Pterodactyl został zainstalowany."
}

pterodactyl_read_existing_fqdn() {
  local app_url=""
  if [[ -r /var/www/pterodactyl/.env ]]; then
    app_url=$(grep -m1 '^APP_URL=' /var/www/pterodactyl/.env 2>/dev/null || true)
    app_url=${app_url#APP_URL=}
    app_url=${app_url#\"}
    app_url=${app_url%\"}
    app_url=${app_url#http://}
    app_url=${app_url#https://}
    app_url=${app_url%%/*}
  fi
  printf '%s' "$app_url"
}

pterodactyl_detect_web_ownership() {
  local ownership owner group candidate
  ownership=$(stat -c '%U:%G' /var/www/pterodactyl/storage 2>/dev/null || true)
  owner=${ownership%%:*}
  group=${ownership#*:}
  if [[ -n "$owner" && "$owner" != root && "$owner" != UNKNOWN ]] \
    && id "$owner" >/dev/null 2>&1 && getent group "$group" >/dev/null 2>&1; then
    printf '%s:%s' "$owner" "$group"
    return 0
  fi

  for candidate in www-data nginx apache; do
    if id "$candidate" >/dev/null 2>&1; then
      printf '%s:%s' "$candidate" "$candidate"
      return 0
    fi
  done
  return 1
}

pterodactyl_composer_major() {
  sed -nE 's/.*[Cc]omposer([^0-9]+)([0-9]+)\..*/\2/p' <<<"$1" | head -n 1
}

pterodactyl_update_runtime_preflight() {
  local manage_blueprint=${1:-true} php_version composer_version composer_major composer_detected
  pterodactyl_preflight || return 1
  pterodactyl_panel_installed || {
    ui_error "Nie wykryto panelu Pterodactyl do aktualizacji."
    return 1
  }
  require_commands php composer curl tar chmod chown stat id getent awk sed grep mktemp || return 1

  if command -v timeout >/dev/null 2>&1; then
    php_version=$(timeout 10s php -r 'echo PHP_VERSION_ID;' 2>/dev/null || true)
  else
    php_version=$(php -r 'echo PHP_VERSION_ID;' 2>/dev/null || true)
  fi
  if [[ ! "$php_version" =~ ^[0-9]+$ ]] || ((php_version < 80200)); then
    ui_error "Aktualizacja Panelu wymaga PHP 8.2 lub nowszego."
    return 1
  fi
  if command -v timeout >/dev/null 2>&1; then
    composer_version=$(COMPOSER_ALLOW_SUPERUSER=1 timeout 10s composer --no-ansi --version 2>&1 || true)
  else
    composer_version=$(COMPOSER_ALLOW_SUPERUSER=1 composer --no-ansi --version 2>&1 || true)
  fi
  composer_major=$(pterodactyl_composer_major "$composer_version")
  if [[ "$composer_major" != 2 ]]; then
    composer_detected=$(sed -n '/[Cc]omposer/{s/^[[:space:]]*//;p;q;}' <<<"$composer_version")
    ui_error "Aktualizacja Panelu wymaga Composer 2.x. Wykryto: ${composer_detected:-brak odpowiedzi z polecenia composer}."
    return 1
  fi

  PTERO_UPDATE_OWNERSHIP=$(pterodactyl_detect_web_ownership) || {
    ui_error "Nie udało się wykryć użytkownika i grupy serwera WWW."
    return 1
  }
  PTERO_UPDATE_HAS_BLUEPRINT=false
  if declare -F blueprint_installed >/dev/null 2>&1 && blueprint_installed; then
    if [[ "$manage_blueprint" == true ]]; then
      require_commands blueprint || return 1
      PTERO_UPDATE_HAS_BLUEPRINT=true
    fi
  fi
}

pterodactyl_panel_update_versions() {
  require_linux || return 1
  require_commands curl || return 1
  pterodactyl_panel_installed || {
    ui_error "Nie wykryto panelu Pterodactyl do aktualizacji."
    return 1
  }
  PTERO_CURRENT_VERSION=$(pterodactyl_panel_version)
  if [[ ! "${PTERO_CURRENT_VERSION#v}" =~ ^1\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
    ui_error "Nie udało się potwierdzić wersji Panelu z serii 1.x. Aktualizacja przerwana."
    return 1
  fi
  PTERO_LATEST_VERSION=$(pterodactyl_latest_release_version panel 2>/dev/null || true)
  if [[ -z "$PTERO_LATEST_VERSION" ]]; then
    ui_error "Nie udało się sprawdzić najnowszego stabilnego wydania Panelu na GitHubie."
    return 1
  fi
  PTERO_UPDATE_ARCHIVE_URL="https://github.com/pterodactyl/panel/releases/download/v${PTERO_LATEST_VERSION}/panel.tar.gz"
}

pterodactyl_update_abort() {
  local archive=${1:-} listing=${2:-}
  [[ "$archive" == /tmp/blackhost-pterodactyl-panel.* ]] && rm -f -- "$archive"
  [[ "$listing" == /tmp/blackhost-pterodactyl-list.* ]] && rm -f -- "$listing"
  if [[ "${PTERO_UPDATE_MAINTENANCE:-false}" == true ]]; then
    (cd /var/www/pterodactyl && php artisan up) >/dev/null 2>&1 || true
  fi
  return 1
}

pterodactyl_update_panel_impl() {
  local archive listing archive_url
  archive_url=${PTERO_UPDATE_ARCHIVE_URL:-https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz}
  PTERO_UPDATE_MAINTENANCE=false
  archive=$(mktemp /tmp/blackhost-pterodactyl-panel.XXXXXX) || return 1
  listing=$(mktemp /tmp/blackhost-pterodactyl-list.XXXXXX) || {
    pterodactyl_update_abort "$archive" ""
    return 1
  }
  trap 'pterodactyl_update_abort "${archive:-}" "${listing:-}"; exit 130' INT TERM HUP

  printf 'BlackHost stage: panel update download\n'
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 300 --output "$archive" "$archive_url" || {
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }

  printf 'BlackHost stage: panel update validate\n'
  tar -tzf "$archive" >"$listing" || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }
  if grep -Eq '(^|/)\.\.(/|$)|^/' "$listing" || ! grep -Eq '^(\./)?artisan$' "$listing"; then
    printf 'Pobrane archiwum Panelu ma nieoczekiwaną strukturę.\n' >&2
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  fi
  rm -f -- "$listing"
  listing=""

  printf 'BlackHost stage: panel update maintenance\n'
  (cd /var/www/pterodactyl && php artisan down) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }
  PTERO_UPDATE_MAINTENANCE=true

  if [[ "${PTERO_UPDATE_CLEAN_PANEL_FILES:-false}" == true ]]; then
    printf 'BlackHost stage: panel update clean\n'
    [[ -f /var/www/pterodactyl/.env && -f /var/www/pterodactyl/artisan ]] || {
      printf 'Odmowa czyszczenia: katalog Panelu nie ma oczekiwanej struktury.\n' >&2
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }
    find /var/www/pterodactyl -mindepth 1 -maxdepth 1 ! -name '.*' \
      -exec rm -rf -- {} + || {
        pterodactyl_update_abort "$archive" "$listing"
        return 1
      }
    [[ -f /var/www/pterodactyl/.env ]] || {
      printf 'Plik .env Panelu nie został zachowany. Operacja przerwana.\n' >&2
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }
  fi

  if [[ "${PTERO_UPDATE_REMOVE_BLUEPRINT:-false}" == true ]]; then
    printf 'BlackHost stage: blueprint uninstall remove\n'
    rm -rf -- /var/www/pterodactyl/.blueprint || {
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }
    rm -f -- /var/www/pterodactyl/.blueprintrc /usr/local/bin/blueprint || {
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }
  fi

  printf 'BlackHost stage: panel update extract\n'
  tar -xzf "$archive" -C /var/www/pterodactyl || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }
  rm -f -- "$archive"
  archive=""

  printf 'BlackHost stage: panel update permissions\n'
  (cd /var/www/pterodactyl && chmod -R 755 storage/* bootstrap/cache) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }

  printf 'BlackHost stage: panel update composer\n'
  (cd /var/www/pterodactyl && COMPOSER_ALLOW_SUPERUSER=1 \
    composer install --no-dev --optimize-autoloader --no-interaction) || {
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }

  printf 'BlackHost stage: panel update cache\n'
  (cd /var/www/pterodactyl && php artisan view:clear && php artisan config:clear) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }

  printf 'BlackHost stage: panel update migrations\n'
  (cd /var/www/pterodactyl && php artisan migrate --seed --force) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }

  printf 'BlackHost stage: panel update ownership\n'
  (cd /var/www/pterodactyl && chown -R "$PTERO_UPDATE_OWNERSHIP" ./*) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }

  printf 'BlackHost stage: panel update queue\n'
  (cd /var/www/pterodactyl && php artisan queue:restart) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }

  if [[ "$PTERO_UPDATE_HAS_BLUEPRINT" == true ]]; then
    printf 'BlackHost stage: panel update blueprint\n'
    printf 'y\n\n' | blueprint -upgrade || {
      pterodactyl_update_abort "$archive" "$listing"
      return 1
    }
  fi

  printf 'BlackHost stage: panel update online\n'
  (cd /var/www/pterodactyl && php artisan up) || {
    pterodactyl_update_abort "$archive" "$listing"
    return 1
  }
  PTERO_UPDATE_MAINTENANCE=false
  printf 'BlackHost stage: panel update complete\n'
  trap - INT TERM HUP
}

pterodactyl_update_panel() {
  local target_version new_version
  ui_header "AKTUALIZACJA PANELU"
  ui_section "WERYFIKACJA"
  ui_info "Sprawdzam zainstalowaną i najnowszą stabilną wersję Panelu."
  pterodactyl_panel_update_versions || return 0
  PTERO_UPDATE_CLEAN_PANEL_FILES=false
  PTERO_UPDATE_REMOVE_BLUEPRINT=false
  target_version="v${PTERO_LATEST_VERSION#v}"

  if [[ "${PTERO_CURRENT_VERSION#v}" == "${PTERO_LATEST_VERSION#v}" ]]; then
    ui_success "Panel jest już aktualny (v${PTERO_CURRENT_VERSION#v})."
    return 0
  fi

  ui_info "Dostępna jest wersja v${PTERO_LATEST_VERSION#v}. Sprawdzam PHP, Composer i uprawnienia plików."
  pterodactyl_update_runtime_preflight || return 0

  ui_section "PODSUMOWANIE"
  ui_summary_row "Obecna wersja" "v${PTERO_CURRENT_VERSION#v}"
  ui_summary_row "Wersja docelowa" "$target_version"
  ui_summary_row "Panel" "/var/www/pterodactyl"
  if [[ "$PTERO_UPDATE_HAS_BLUEPRINT" == true ]]; then
    ui_summary_row "Blueprint" "Zostanie ponownie nałożony"
  fi
  printf '\n'
  ui_warn "Panel zostanie tymczasowo przełączony w tryb konserwacji."
  ui_warn "Domyślne eggi Pterodactyla mogą zostać nadpisane podczas migracji."
  ui_warn "Po aktualizacji sprawdź zgodność wersji Wings z wersją Panelu."
  ui_confirm "Rozpocząć aktualizację Panelu?" y || return 0

  if ! run_with_progress "pterodactyl-panel-update" pterodactyl_update_panel_impl; then
    ui_error "Aktualizacja Panelu nie została dokończona. Panel został wyprowadzony z trybu konserwacji, jeśli było to możliwe."
    return 0
  fi

  new_version=$(pterodactyl_panel_version)
  if [[ "${new_version#v}" != "${PTERO_LATEST_VERSION#v}" ]]; then
    ui_error "Aktualizacja zakończyła się, ale wykryto v${new_version#v} zamiast oczekiwanej v${PTERO_LATEST_VERSION#v}."
    return 0
  fi
  write_state pterodactyl-panel-update \
    "previous_version=${PTERO_CURRENT_VERSION}" \
    "version=${new_version:-unknown}"
  ui_success "Panel Pterodactyl został zaktualizowany${new_version:+ do v${new_version#v}}."
}

pterodactyl_finish_panel_impl() {
  local cron_line='* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1'
  local os_id web_user php_socket config_available config_enabled template
  os_id=$(. /etc/os-release; printf '%s' "$ID")

  printf 'Etap: cron\n'
  if ! crontab -l 2>/dev/null | grep -qF '/var/www/pterodactyl/artisan schedule:run'; then
    { crontab -l 2>/dev/null || true; printf '%s\n' "$cron_line"; } | crontab - || return 1
  fi

  printf 'Etap: pteroq\n'
  case "$os_id" in
    ubuntu|debian) web_user="www-data"; php_socket="/run/php/php8.3-fpm.sock" ;;
    rocky|almalinux) web_user="nginx"; php_socket="/var/run/php-fpm/pterodactyl.sock" ;;
    *) printf 'Nieobsługiwany system: %s\n' "$os_id" >&2; return 1 ;;
  esac
  install -m 644 "${PTERO_SOURCE_DIR}/configs/pteroq.service" /etc/systemd/system/pteroq.service || return 1
  sed -i -e "s@<user>@${web_user}@g" /etc/systemd/system/pteroq.service || return 1
  systemctl daemon-reload || return 1
  systemctl enable --now pteroq.service || return 1

  printf 'Etap: nginx\n'
  if [[ "$os_id" == "ubuntu" || "$os_id" == "debian" ]]; then
    config_available="/etc/nginx/sites-available/pterodactyl.conf"
    config_enabled="/etc/nginx/sites-enabled/pterodactyl.conf"
  else
    config_available="/etc/nginx/conf.d/pterodactyl.conf"
    config_enabled="$config_available"
  fi
  template="${PTERO_SOURCE_DIR}/configs/nginx.conf"
  [[ "$PTERO_REPAIR_ASSUME_SSL" == true ]] && template="${PTERO_SOURCE_DIR}/configs/nginx_ssl.conf"
  install -m 644 "$template" "$config_available" || return 1
  sed -i -e "s@<domain>@${PTERO_REPAIR_FQDN}@g" -e "s@<php_socket>@${php_socket}@g" "$config_available" || return 1
  if [[ "$config_enabled" != "$config_available" ]]; then
    rm -f /etc/nginx/sites-enabled/default || return 1
    ln -sfn "$config_available" "$config_enabled" || return 1
  fi
  nginx -t || return 1
  systemctl restart nginx || return 1

  if [[ "$PTERO_REPAIR_LETSENCRYPT" == true ]]; then
    printf 'Etap: certyfikat\n'
    certbot --nginx --redirect --non-interactive --agree-tos --no-eff-email --email "$PTERO_REPAIR_EMAIL" -d "$PTERO_REPAIR_FQDN" || return 1
  fi
}

pterodactyl_finish_panel() {
  pterodactyl_preflight || return 0
  pterodactyl_panel_installed || {
    ui_error "Nie wykryto plików panelu do naprawy."
    return 0
  }
  if pterodactyl_panel_healthy; then
    ui_success "Panel jest już kompletnie skonfigurowany."
    return 0
  fi

  ui_header "NAPRAWA PANELU"
  ui_section "BRAKUJĄCE ELEMENTY"
  ui_info "CLI skonfiguruje cron, kolejkę pteroq oraz Nginx."
  PTERO_REPAIR_FQDN=$(pterodactyl_read_existing_fqdn)
  while ! valid_fqdn "$PTERO_REPAIR_FQDN"; do
    ui_prompt PTERO_REPAIR_FQDN "Domena istniejącego panelu" "panel.example.com"
    valid_fqdn "$PTERO_REPAIR_FQDN" || ui_error "Podaj pełną domenę panelu."
  done
  ui_confirm "Pobrać certyfikat HTTPS z Let's Encrypt?" y && PTERO_REPAIR_LETSENCRYPT=true || PTERO_REPAIR_LETSENCRYPT=false
  if [[ "$PTERO_REPAIR_LETSENCRYPT" == true ]]; then
    ui_warn "Let's Encrypt wymaga otwartego z internetu portu TCP 80."
    ui_confirm "Akceptujesz warunki usługi Let's Encrypt?" y || PTERO_REPAIR_LETSENCRYPT=false
  fi
  PTERO_REPAIR_ASSUME_SSL=false
  PTERO_REPAIR_EMAIL="admin@example.pl"
  if [[ "$PTERO_REPAIR_LETSENCRYPT" == true ]]; then
    ui_prompt PTERO_REPAIR_EMAIL "E-mail Let's Encrypt" "admin@example.pl"
    valid_email "$PTERO_REPAIR_EMAIL" || {
      ui_error "Nieprawidłowy adres e-mail."
      return 0
    }
  else
    ui_confirm "Użyć istniejącego certyfikatu w /etc/ssl?" n && PTERO_REPAIR_ASSUME_SSL=true || true
  fi
  ui_confirm "Dokończyć konfigurację panelu?" y || return 0

  export PTERO_REPAIR_FQDN PTERO_REPAIR_EMAIL PTERO_REPAIR_LETSENCRYPT PTERO_REPAIR_ASSUME_SSL
  pterodactyl_fetch_upstream || return 0
  if ! run_with_progress "pterodactyl-panel-repair" pterodactyl_finish_panel_impl; then
    pterodactyl_cleanup_upstream
    ui_error "Nie udało się dokończyć konfiguracji panelu."
    return 0
  fi
  pterodactyl_cleanup_upstream

  if ! pterodactyl_panel_healthy; then
    ui_error "Naprawa zakończyła się, ale kontrola usług nadal wykrywa problem."
    return 0
  fi
  write_state pterodactyl-panel \
    "upstream_version=${PTERO_INSTALLER_VERSION}" \
    "fqdn=${PTERO_REPAIR_FQDN}"
  ui_success "Konfiguracja panelu została dokończona."
}

pterodactyl_prompt_wings() {
  ui_header "INSTALACJA WINGS"
  ui_section "KONFIGURACJA"
  ui_info "Skonfiguruj noda i opcjonalny dostęp do bazy panelu."

  ui_confirm "Skonfigurować firewall UFW dla portów 22, 8080 i 2022? Niezalecane, jeżeli korzystasz z firewalla panelowego" n && WINGS_FIREWALL=true || WINGS_FIREWALL=false
  ui_confirm "Utworzyć użytkownika MariaDB dla zdalnych hostów?" n && WINGS_DBHOST=true || WINGS_DBHOST=false
  WINGS_DB_EXTERNAL=false
  WINGS_DB_FIREWALL=false
  WINGS_DB_HOST="127.0.0.1"
  WINGS_DB_USER="pterodactyluser"
  WINGS_DB_PASSWORD=""

  if [[ "$WINGS_DBHOST" == true ]]; then
    ui_confirm "Pozwolić na zdalne połączenia do MariaDB?" n && WINGS_DB_EXTERNAL=true || true
    if [[ "$WINGS_DB_EXTERNAL" == true ]]; then
      ui_prompt WINGS_DB_HOST "Adres IP panelu uprawniony do MariaDB" ""
      valid_ipv4 "$WINGS_DB_HOST" || {
        ui_error "Podaj konkretny adres IPv4 panelu."
        return 1
      }
      ui_confirm "Otworzyć port 3306 w firewallu?" n && WINGS_DB_FIREWALL=true || true
    fi
    ui_prompt WINGS_DB_USER "Użytkownik hosta bazy" "pterodactyluser"
    valid_db_identifier "$WINGS_DB_USER" || {
      ui_error "Nieprawidłowa nazwa użytkownika bazy."
      return 1
    }
    WINGS_DB_PASSWORD=$(random_secret)
  fi

  ui_confirm "Pobrać osobny certyfikat Let's Encrypt dla Wings?" n && WINGS_LETSENCRYPT=true || WINGS_LETSENCRYPT=false
  if [[ "$WINGS_LETSENCRYPT" == true ]]; then
    ui_warn "Let's Encrypt wymaga otwartego z internetu portu TCP 80."
    ui_confirm "Akceptujesz warunki usługi Let's Encrypt?" y || WINGS_LETSENCRYPT=false
  fi
  WINGS_FQDN=""
  WINGS_EMAIL=""
  if [[ "$WINGS_LETSENCRYPT" == true ]]; then
    ui_prompt WINGS_FQDN "Domena noda" "node.example.com"
    valid_fqdn "$WINGS_FQDN" || {
      ui_error "Nieprawidłowa domena noda."
      return 1
    }
    ui_prompt WINGS_EMAIL "E-mail Let's Encrypt" "admin@${WINGS_FQDN#*.}"
    valid_email "$WINGS_EMAIL" || {
      ui_error "Nieprawidłowy adres e-mail."
      return 1
    }
  fi

  local wings_https_summary
  if [[ "$WINGS_LETSENCRYPT" == true ]]; then
    wings_https_summary="${BH_GREEN}Let's Encrypt${BH_RESET}"
  else
    wings_https_summary="${BH_MUTED}Wyłączony${BH_RESET}"
  fi

  ui_section "PODSUMOWANIE INSTALACJI"
  ui_summary_group "WINGS"
  ui_summary_row "Firewall UFW" "$(ui_state_value "$WINGS_FIREWALL")"
  ui_summary_row "HTTPS" "$wings_https_summary"
  if [[ "$WINGS_LETSENCRYPT" == true ]]; then
    ui_summary_row "Domena" "$WINGS_FQDN"
    ui_summary_row "E-mail" "$WINGS_EMAIL"
  fi

  ui_summary_group "DOSTĘP DO BAZY"
  ui_summary_row "Host bazy" "$(ui_state_value "$WINGS_DBHOST" 'Konfigurowany' 'Pominięty')"
  if [[ "$WINGS_DBHOST" == true ]]; then
    ui_summary_row "Użytkownik" "$WINGS_DB_USER"
    ui_summary_row "Hasło" "$WINGS_DB_PASSWORD (wygenerowane)"
    ui_summary_row "Połączenia zdalne" "$(ui_state_value "$WINGS_DB_EXTERNAL" 'Dozwolone' 'Wyłączone')"
    if [[ "$WINGS_DB_EXTERNAL" == true ]]; then
      ui_summary_row "Dozwolony adres IP" "$WINGS_DB_HOST"
      ui_summary_row "Port 3306 w UFW" "$(ui_state_value "$WINGS_DB_FIREWALL" 'Otwarty' 'Zamknięty')"
    fi
  fi
  printf '\n'
  ui_warn "Po instalacji trzeba wkleić config.yml noda z panelu i uruchomić usługę Wings."
  ui_confirm "Rozpocząć instalację?" y
}

pterodactyl_install_wings_impl() {
  export CONFIGURE_FIREWALL="$WINGS_FIREWALL"
  export CONFIGURE_DBHOST="$WINGS_DBHOST"
  export CONFIGURE_DB_FIREWALL="$WINGS_DB_FIREWALL"
  export MYSQL_DBHOST_HOST="$WINGS_DB_HOST"
  export MYSQL_DBHOST_USER="$WINGS_DB_USER"
  export MYSQL_DBHOST_PASSWORD="$WINGS_DB_PASSWORD"
  export INSTALL_MARIADB="$WINGS_DBHOST"
  export CONFIGURE_LETSENCRYPT="$WINGS_LETSENCRYPT"
  export FQDN="$WINGS_FQDN"
  export EMAIL="$WINGS_EMAIL"

  pterodactyl_run_upstream wings
}

pterodactyl_install_wings() {
  PTERO_ACTION_COMPLETED=false
  pterodactyl_preflight || return 0
  if pterodactyl_wings_installed; then
    ui_error "Wings jest już zainstalowane."
    return 0
  fi
  pterodactyl_prompt_wings || return 0
  pterodactyl_fetch_upstream || return 0

  if ! run_with_progress "pterodactyl-wings-install" pterodactyl_install_wings_impl; then
    pterodactyl_cleanup_upstream
    ui_error "Instalacja Wings nie została dokończona."
    return 0
  fi
  pterodactyl_cleanup_upstream
  write_state pterodactyl-wings "upstream_version=${PTERO_INSTALLER_VERSION}"
  PTERO_ACTION_COMPLETED=true
  ui_success "Wings zostało zainstalowane. Dodaj teraz /etc/pterodactyl/config.yml."
}

pterodactyl_update_wings_preflight() {
  pterodactyl_preflight || return 1
  require_commands systemctl cp chmod mktemp || return 1
  [[ -x /usr/local/bin/wings ]] || {
    ui_error "Nie znaleziono pliku wykonywalnego /usr/local/bin/wings."
    return 1
  }
  WINGS_UPDATE_ARCH=$(pterodactyl_wings_architecture) || {
    ui_error "Aktualizacja Wings obsługuje architekturę amd64 oraz arm64."
    return 1
  }
  WINGS_CURRENT_VERSION=$(pterodactyl_wings_version) || {
    ui_error "Nie udało się odczytać zainstalowanej wersji Wings."
    return 1
  }
  WINGS_LATEST_VERSION=$(pterodactyl_latest_release_version wings 2>/dev/null || true)
  if [[ -z "$WINGS_LATEST_VERSION" ]]; then
    ui_error "Nie udało się sprawdzić najnowszego stabilnego wydania Wings na GitHubie."
    return 1
  fi
  WINGS_UPDATE_URL="https://github.com/pterodactyl/wings/releases/download/v${WINGS_LATEST_VERSION}/wings_linux_${WINGS_UPDATE_ARCH}"
}

pterodactyl_update_wings_abort() {
  local downloaded=${1:-} previous=${2:-}
  if [[ "${WINGS_UPDATE_STOPPED:-false}" == true ]]; then
    if [[ "$previous" == /tmp/blackhost-wings-previous.* && -s "$previous" ]]; then
      install -m 755 "$previous" /usr/local/bin/wings >/dev/null 2>&1 || true
    fi
    systemctl restart wings >/dev/null 2>&1 || true
  fi
  [[ "$downloaded" == /tmp/blackhost-wings-download.* ]] && rm -f -- "$downloaded"
  [[ "$previous" == /tmp/blackhost-wings-previous.* ]] && rm -f -- "$previous"
  return 1
}

pterodactyl_update_wings_impl() {
  local downloaded previous downloaded_version installed_version
  WINGS_UPDATE_STOPPED=false
  downloaded=$(mktemp /tmp/blackhost-wings-download.XXXXXX) || return 1
  previous=$(mktemp /tmp/blackhost-wings-previous.XXXXXX) || {
    pterodactyl_update_wings_abort "$downloaded" ""
    return 1
  }
  trap 'pterodactyl_update_wings_abort "${downloaded:-}" "${previous:-}"; exit 130' INT TERM HUP

  printf 'BlackHost stage: wings update download\n'
  curl --fail --location --silent --show-error --connect-timeout 15 --max-time 300 \
    --proto '=https' --tlsv1.2 --output "$downloaded" "$WINGS_UPDATE_URL" || {
      pterodactyl_update_wings_abort "$downloaded" "$previous"
      return 1
    }
  chmod 755 "$downloaded" || {
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  }

  printf 'BlackHost stage: wings update validate\n'
  downloaded_version=$(pterodactyl_wings_version "$downloaded" 2>/dev/null || true)
  if [[ "${downloaded_version#v}" != "${WINGS_LATEST_VERSION#v}" ]]; then
    printf 'Pobrana binarka Wings ma wersję %s zamiast %s.\n' \
      "${downloaded_version:-nieznaną}" "$WINGS_LATEST_VERSION" >&2
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  fi
  cp /usr/local/bin/wings "$previous" || {
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  }

  printf 'BlackHost stage: wings update stop\n'
  systemctl stop wings || {
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  }
  WINGS_UPDATE_STOPPED=true

  printf 'BlackHost stage: wings update install\n'
  install -m 755 "$downloaded" /usr/local/bin/wings || {
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  }
  hash -r

  printf 'BlackHost stage: wings update restart\n'
  systemctl restart wings || {
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  }

  printf 'BlackHost stage: wings update verify\n'
  systemctl is-active --quiet wings || {
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  }
  installed_version=$(pterodactyl_wings_version 2>/dev/null || true)
  if [[ "${installed_version#v}" != "${WINGS_LATEST_VERSION#v}" ]]; then
    pterodactyl_update_wings_abort "$downloaded" "$previous"
    return 1
  fi
  WINGS_UPDATE_STOPPED=false
  rm -f -- "$downloaded" "$previous"
  printf 'BlackHost stage: wings update complete\n'
  trap - INT TERM HUP
}

pterodactyl_update_wings() {
  ui_header "AKTUALIZACJA WINGS"
  ui_section "WERYFIKACJA"
  ui_info "Sprawdzam wersję Wings, architekturę serwera i najnowsze wydanie."
  pterodactyl_update_wings_preflight || return 0

  if [[ "${WINGS_CURRENT_VERSION#v}" == "${WINGS_LATEST_VERSION#v}" ]]; then
    ui_success "Wings jest już aktualne (v${WINGS_CURRENT_VERSION#v})."
    return 0
  fi

  ui_section "PODSUMOWANIE"
  ui_summary_row "Obecna wersja" "v${WINGS_CURRENT_VERSION#v}"
  ui_summary_row "Wersja docelowa" "v${WINGS_LATEST_VERSION#v}"
  ui_summary_row "Architektura" "$WINGS_UPDATE_ARCH"
  printf '\n'
  ui_info "Usługa Wings zostanie krótko zatrzymana; uruchomione serwery gier pozostaną aktywne."
  ui_confirm "Rozpocząć aktualizację Wings?" y || return 0

  if ! run_with_progress "pterodactyl-wings-update" pterodactyl_update_wings_impl; then
    ui_error "Aktualizacja Wings nie została dokończona. W razie podmiany CLI spróbowało przywrócić poprzednią binarkę."
    return 0
  fi
  write_state pterodactyl-wings \
    "previous_version=${WINGS_CURRENT_VERSION}" \
    "version=${WINGS_LATEST_VERSION}"
  ui_success "Wings zostało zaktualizowane do v${WINGS_LATEST_VERSION#v}."
}

pterodactyl_uninstall_panel_impl() {
  export RM_PANEL=true RM_WINGS=false
  export BLACKHOST_DATABASE_MODE=managed
  export BLACKHOST_REMOVE_DATABASE="$PTERO_REMOVE_DATABASE"
  export BLACKHOST_REMOVE_DB_USER="$PTERO_REMOVE_DB_USER"
  export DATABASE="$PTERO_DATABASE_TO_REMOVE"
  export DB_USER="$PTERO_DB_USER_TO_REMOVE"
  pterodactyl_run_upstream uninstall
}

pterodactyl_uninstall_wings_impl() {
  export RM_PANEL=false RM_WINGS=true
  pterodactyl_run_upstream uninstall
}

pterodactyl_uninstall_panel() {
  pterodactyl_preflight || return 0
  pterodactyl_panel_installed || {
    ui_error "Nie wykryto panelu Pterodactyl."
    return 0
  }

  ui_header "USUWANIE PANELU"
  ui_section "ZAKRES OPERACJI"
  ui_warn "Pełne odinstalowanie wykona pterodactyl-installer ${PTERO_INSTALLER_VERSION}."
  ui_warn "Panel, zadania cron i usługi panelu zostaną usunięte."

  PTERO_DATABASE_TO_REMOVE=$(pterodactyl_read_panel_env_value DB_DATABASE panel)
  PTERO_DB_USER_TO_REMOVE=$(pterodactyl_read_panel_env_value DB_USERNAME pterodactyl)
  ui_confirm "Usunąć również bazę danych panelu?" n && PTERO_REMOVE_DATABASE=true || PTERO_REMOVE_DATABASE=false
  if [[ "$PTERO_REMOVE_DATABASE" == true ]]; then
    while :; do
      ui_prompt PTERO_DATABASE_TO_REMOVE "Nazwa bazy danych do usunięcia" "$PTERO_DATABASE_TO_REMOVE"
      valid_db_identifier "$PTERO_DATABASE_TO_REMOVE" && break
      ui_error "Nieprawidłowa nazwa bazy danych."
    done
  fi
  ui_confirm "Usunąć również użytkownika bazy danych panelu?" n && PTERO_REMOVE_DB_USER=true || PTERO_REMOVE_DB_USER=false
  if [[ "$PTERO_REMOVE_DB_USER" == true ]]; then
    while :; do
      ui_prompt PTERO_DB_USER_TO_REMOVE "Użytkownik bazy danych do usunięcia" "$PTERO_DB_USER_TO_REMOVE"
      valid_db_identifier "$PTERO_DB_USER_TO_REMOVE" && break
      ui_error "Nieprawidłowa nazwa użytkownika bazy danych."
    done
  fi

  local phrase
  ui_prompt phrase "Aby kontynuować, wpisz: USUN PANEL" ""
  [[ "$phrase" == "USUN PANEL" ]] || {
    ui_info "Anulowano."
    return 0
  }

  pterodactyl_fetch_upstream || return 0
  if ! pterodactyl_prepare_managed_uninstaller; then
    pterodactyl_cleanup_upstream
    return 0
  fi
  if ! run_with_progress "pterodactyl-panel-uninstall" pterodactyl_uninstall_panel_impl; then
    pterodactyl_cleanup_upstream
    ui_error "Odinstalowanie panelu nie zostało dokończone."
    return 0
  fi
  pterodactyl_cleanup_upstream
  systemctl daemon-reload || true
  rm -f "${BLACKHOST_STATE_DIR}/pterodactyl-panel.state"
  ui_success "Panel został odinstalowany przez pterodactyl-installer."
}

pterodactyl_uninstall_wings() {
  pterodactyl_preflight || return 0
  pterodactyl_wings_installed || {
    ui_error "Nie wykryto Wings."
    return 0
  }

  ui_header "USUWANIE WINGS"
  ui_section "ZAKRES OPERACJI"
  ui_warn "Pełne odinstalowanie wykona pterodactyl-installer ${PTERO_INSTALLER_VERSION}."
  ui_warn "Wings i wszystkie dane w /var/lib/pterodactyl zostaną bezpowrotnie usunięte."
  ui_warn "Instalator wykona docker system prune -a -f i usunie nieużywane zasoby Dockera."
  local phrase
  ui_prompt phrase "Aby kontynuować, wpisz: USUN WINGS I DANE" ""
  [[ "$phrase" == "USUN WINGS I DANE" ]] || {
    ui_info "Anulowano."
    return 0
  }

  pterodactyl_fetch_upstream || return 0
  if ! run_with_progress "pterodactyl-wings-uninstall" pterodactyl_uninstall_wings_impl; then
    pterodactyl_cleanup_upstream
    ui_error "Odinstalowanie Wings nie zostało dokończone."
    return 0
  fi
  pterodactyl_cleanup_upstream
  systemctl daemon-reload || true
  rm -f "${BLACKHOST_STATE_DIR}/pterodactyl-wings.state"
  ui_success "Wings i dane zostały usunięte przez pterodactyl-installer."
}

pterodactyl_menu() {
  local choice panel_version header
  while :; do
    panel_version=$(pterodactyl_panel_version)
    header="PTERODACTYL"
    [[ -n "$panel_version" ]] && header+=" · v${panel_version#v}"
    ui_header "$header"
    ui_section "STAN"
    pterodactyl_status "$panel_version"
    blueprint_status
    nginx_status
    ui_section "AKCJE"
    ui_option 1 "Zainstaluj Panel" "Nginx, PHP, MariaDB i Redis"
    ui_option 2 "Zainstaluj Wings" "Docker i usługa systemd"
    ui_option 3 "Zainstaluj Panel + Wings" "Instalacja na jednym hoście"
    ui_option 4 "Zainstaluj Blueprint" "Framework rozszerzeń Pterodactyl"
    ui_option 5 "Aktualizuj Panel" "Najnowsze stabilne wydanie 1.x"
    ui_option 6 "Aktualizuj Wings" "Najnowsza binarka dla amd64/arm64"
    ui_option 7 "Dokończ / napraw Panel" "Cron, pteroq, Nginx i SSL"
    ui_option 8 "Odinstaluj Blueprint" "Odtwarza czysty Panel Pterodactyl"
    ui_option 9 "Odinstaluj Panel" "Pełny tryb pterodactyl-installer"
    ui_option 10 "Odinstaluj Wings" "Usuwa dane i zasoby Dockera"
    ui_option 0 "Wróć" "Lista programów"
    ui_menu_prompt choice

    case "$choice" in
      1) pterodactyl_install_panel; ui_pause ;;
      2) pterodactyl_install_wings; ui_pause ;;
      3)
        pterodactyl_install_panel
        if [[ "$PTERO_ACTION_COMPLETED" == true ]]; then
          pterodactyl_install_wings
        else
          ui_warn "Instalacja Wings została pominięta, ponieważ panel nie został zainstalowany."
        fi
        ui_pause
        ;;
      4) blueprint_install; ui_pause ;;
      5) pterodactyl_update_panel; ui_pause ;;
      6) pterodactyl_update_wings; ui_pause ;;
      7) pterodactyl_finish_panel; ui_pause ;;
      8) blueprint_uninstall; ui_pause ;;
      9) pterodactyl_uninstall_panel; ui_pause ;;
      10) pterodactyl_uninstall_wings; ui_pause ;;
      0) return 0 ;;
      *) ui_error "Nieprawidłowa opcja."; sleep 1 ;;
    esac
  done
}
