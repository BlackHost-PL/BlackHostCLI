#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

BLACKHOST_VERSION="1.2.0"
BLACKHOST_OPERATION_LOCK_HELD=false
BLACKHOST_STATE_DIR="${BLACKHOST_STATE_DIR:-/var/lib/blackhost}"
BLACKHOST_LOG_DIR="${BLACKHOST_LOG_DIR:-/var/log/blackhost}"

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || {
    ui_error "BlackHost CLI działa wyłącznie na Linuksie."
    return 1
  }
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    ui_error "Ta operacja wymaga konta root. Uruchom: sudo blackhost"
    return 1
  }
}

require_commands() {
  local command_name missing=0
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      ui_error "Brakuje wymaganego polecenia: $command_name"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]]
}

ensure_runtime_dirs() {
  install -d -m 700 "$BLACKHOST_STATE_DIR"
  install -d -m 750 "$BLACKHOST_LOG_DIR"
}

acquire_operation_lock() {
  [[ "$BLACKHOST_OPERATION_LOCK_HELD" == true ]] && return 0
  require_commands flock || return 1
  ensure_runtime_dirs || return 1
  exec 9>"${BLACKHOST_STATE_DIR}/operation.lock"
  flock -n 9 || {
    ui_error "Inna operacja BlackHost CLI jest już uruchomiona."
    return 1
  }
  BLACKHOST_OPERATION_LOCK_HELD=true
}

release_operation_lock() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  BLACKHOST_OPERATION_LOCK_HELD=false
}

run_logged() {
  local action=$1
  shift
  local log_file="${BLACKHOST_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-${action}.log"

  ui_info "Log operacji: $log_file"
  "$@" 2>&1 | tee -a "$log_file"
}

progress_package_stats() {
  local log_file=$1
  awk '
    /[0-9]+ upgraded, [0-9]+ newly installed/ {
      upgraded = newly_installed = 0
      for (field = 2; field <= NF; field++) {
        if ($field == "upgraded,") upgraded = $(field - 1)
        if ($field == "newly" && $(field + 1) == "installed,") {
          newly_installed = $(field - 1)
        }
      }
      transaction_total = upgraded + newly_installed
      if (transaction_total > 0) {
        total += transaction_total
        active = 1
      }
    }
    active && /^Get:[0-9]+ / { downloaded++ }
    active && /^Unpacking / { unpacked++ }
    active && /^Setting up / { configured++ }
    END { printf "%d|%d|%d|%d\n", total, downloaded, unpacked, configured }
  ' "$log_file" 2>/dev/null
}

progress_count_percent() {
  local base=$1 span=$2 count=$3 total=$4
  ((total > 0)) || {
    printf '%s' "$base"
    return 0
  }
  ((count > total)) && count=$total
  printf '%s' "$((base + count * span / total))"
}

progress_stage() {
  local action=$1 log_file=$2 current_percent=$3 current_label=$4 snapshot
  local detected_percent=$current_percent detected_label=$current_label
  local package_stats package_total=0 package_downloaded=0 package_unpacked=0 package_configured=0
  snapshot=$(tail -n 120 "$log_file" 2>/dev/null || true)
  package_stats=$(progress_package_stats "$log_file")
  IFS='|' read -r package_total package_downloaded package_unpacked package_configured <<<"$package_stats"
  ((package_downloaded > package_total)) && package_downloaded=$package_total
  ((package_unpacked > package_total)) && package_unpacked=$package_total
  ((package_configured > package_total)) && package_configured=$package_total

  if [[ "$action" == "blackhost-cli-update" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: cli update complete"* ]]; then
      detected_percent=98; detected_label="Nowa wersja jest gotowa"
    elif [[ "$snapshot" == *"BlackHost stage: cli update swap"* ]]; then
      detected_percent=90; detected_label="Aktywowanie nowej wersji"
    elif [[ "$snapshot" == *"BlackHost stage: cli update install"* ]]; then
      detected_percent=72; detected_label="Przygotowywanie nowej instalacji"
    elif [[ "$snapshot" == *"BlackHost stage: cli update validate"* ]]; then
      detected_percent=52; detected_label="Sprawdzanie zawartości wydania"
    elif [[ "$snapshot" == *"BlackHost stage: cli update checksum"* ]]; then
      detected_percent=32; detected_label="Weryfikacja sumy SHA-256"
    elif [[ "$snapshot" == *"BlackHost stage: cli update download"* ]]; then
      detected_percent=10; detected_label="Pobieranie wydania BlackHost CLI"
    fi
  elif [[ "$action" == "phpmyadmin-install" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: phpmyadmin complete"* ]]; then
      detected_percent=98; detected_label="phpMyAdmin jest gotowy"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin verify"* ]]; then
      detected_percent=94; detected_label="Sprawdzanie instalacji"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin certificate"* ]]; then
      detected_percent=86; detected_label="Pobieranie certyfikatu SSL"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin configure"* ]]; then
      detected_percent=72; detected_label="Konfiguracja phpMyAdmin i Nginx"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin database"* ]]; then
      detected_percent=68; detected_label="Tworzenie administratora MariaDB"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin extract"* ]]; then
      detected_percent=64; detected_label="Rozpakowywanie phpMyAdmin"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin checksum"* ]]; then
      detected_percent=56; detected_label="Weryfikacja sumy SHA-256"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin download"* ]]; then
      detected_percent=42; detected_label="Pobieranie phpMyAdmin"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin packages"* ]]; then
      detected_percent=16; detected_label="Instalacja Nginx i PHP-FPM"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin repositories"* ]]; then
      detected_percent=6; detected_label="Aktualizacja listy pakietów"
    fi
  elif [[ "$action" == "phpmyadmin-update" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: phpmyadmin update complete"* ]]; then
      detected_percent=98; detected_label="phpMyAdmin zaktualizowany"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin update swap"* ]]; then
      detected_percent=88; detected_label="Aktywowanie nowej wersji"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin update prepare"* ]]; then
      detected_percent=72; detected_label="Przenoszenie konfiguracji"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin extract"* ]]; then
      detected_percent=58; detected_label="Rozpakowywanie phpMyAdmin"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin checksum"* ]]; then
      detected_percent=38; detected_label="Weryfikacja sumy SHA-256"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin download"* ]]; then
      detected_percent=12; detected_label="Pobieranie phpMyAdmin"
    fi
  elif [[ "$action" == "phpmyadmin-uninstall" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: phpmyadmin uninstall complete"* ]]; then
      detected_percent=98; detected_label="phpMyAdmin usunięty"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin uninstall database"* ]]; then
      detected_percent=92; detected_label="Usuwanie konta bazy"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin uninstall certificate"* ]]; then
      detected_percent=86; detected_label="Usuwanie certyfikatu SSL"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin uninstall files"* ]]; then
      detected_percent=58; detected_label="Usuwanie plików phpMyAdmin"
    elif [[ "$snapshot" == *"BlackHost stage: phpmyadmin uninstall nginx"* ]]; then
      detected_percent=24; detected_label="Usuwanie konfiguracji Nginx"
    fi
  elif [[ "$action" == "pterodactyl-panel-install" ]]; then
    if [[ "$snapshot" == *"Configuring Let's Encrypt"* ]]; then
      detected_percent=99; detected_label="Konfiguracja certyfikatu SSL"
    elif [[ "$snapshot" == *"Configuring nginx"* ]]; then
      detected_percent=98; detected_label="Konfiguracja Nginx"
    elif [[ "$snapshot" == *"Installing pteroq service"* ]]; then
      detected_percent=97; detected_label="Uruchamianie kolejki"
    elif [[ "$snapshot" == *"Installing cronjob"* ]]; then
      detected_percent=96; detected_label="Konfiguracja zadań cron"
    elif [[ "$snapshot" == *"Configured environment"* ]]; then
      detected_percent=95; detected_label="Panel i baza skonfigurowane"
    elif [[ "$snapshot" == *"Configuring environment"* ]]; then
      detected_percent=92; detected_label="Migracje i konfiguracja bazy"
    elif [[ "$snapshot" == *"Installed composer dependencies"* ]]; then
      detected_percent=90; detected_label="Zależności PHP gotowe"
    elif [[ "$snapshot" == *"Installing composer dependencies"* ]]; then
      detected_percent=86; detected_label="Instalacja zależności PHP"
    elif [[ "$snapshot" == *"Downloaded pterodactyl panel files"* ]]; then
      detected_percent=84; detected_label="Pliki panelu pobrane"
    elif [[ "$snapshot" == *"Downloading pterodactyl panel files"* ]]; then
      detected_percent=82; detected_label="Pobieranie panelu"
    elif [[ "$snapshot" == *"Composer installed"* ]]; then
      detected_percent=81; detected_label="Composer gotowy"
    elif [[ "$snapshot" == *"Installing composer"* ]]; then
      detected_percent=78; detected_label="Instalacja Composera"
    elif [[ "$snapshot" == *"Dependencies installed"* ]]; then
      detected_percent=76; detected_label="Pakiety systemowe gotowe"
    elif ((package_total > 0 && package_configured > 0)); then
      detected_percent=$(progress_count_percent 48 26 "$package_configured" "$package_total")
      detected_label="Konfigurowanie pakietów (${package_configured}/${package_total})"
    elif ((package_total > 0 && package_unpacked > 0)); then
      detected_percent=$(progress_count_percent 22 26 "$package_unpacked" "$package_total")
      detected_label="Rozpakowywanie pakietów (${package_unpacked}/${package_total})"
    elif ((package_total > 0 && package_downloaded > 0)); then
      detected_percent=$(progress_count_percent 6 16 "$package_downloaded" "$package_total")
      detected_label="Pobieranie pakietów (${package_downloaded}/${package_total})"
    elif [[ "$snapshot" == *"Processing triggers"* ]]; then
      detected_percent=75; detected_label="Finalizowanie pakietów systemowych"
    elif [[ "$snapshot" == *"Installing dependencies"* ]]; then
      detected_percent=5; detected_label="Przygotowywanie pakietów systemowych"
    fi
  elif [[ "$action" == "pterodactyl-wings-install" ]]; then
    if [[ "$snapshot" == *"Configuring LetsEncrypt"* ]]; then
      detected_percent=98; detected_label="Konfiguracja certyfikatu SSL"
    elif [[ "$snapshot" == *"Configuring MySQL"* ]]; then
      detected_percent=96; detected_label="Konfiguracja MariaDB"
    elif [[ "$snapshot" == *"Installed systemd service"* ]]; then
      detected_percent=94; detected_label="Usługa Wings gotowa"
    elif [[ "$snapshot" == *"Installing systemd service"* ]]; then
      detected_percent=90; detected_label="Konfiguracja systemd"
    elif [[ "$snapshot" == *"Wings downloaded successfully"* ]]; then
      detected_percent=86; detected_label="Wings pobrane"
    elif [[ "$snapshot" == *"Dependencies installed"* ]]; then
      detected_percent=78; detected_label="Pakiety systemowe gotowe"
    elif ((package_total > 0 && package_configured > 0)); then
      detected_percent=$(progress_count_percent 48 28 "$package_configured" "$package_total")
      detected_label="Konfigurowanie pakietów (${package_configured}/${package_total})"
    elif ((package_total > 0 && package_unpacked > 0)); then
      detected_percent=$(progress_count_percent 22 26 "$package_unpacked" "$package_total")
      detected_label="Rozpakowywanie pakietów (${package_unpacked}/${package_total})"
    elif ((package_total > 0 && package_downloaded > 0)); then
      detected_percent=$(progress_count_percent 6 16 "$package_downloaded" "$package_total")
      detected_label="Pobieranie pakietów (${package_downloaded}/${package_total})"
    elif [[ "$snapshot" == *"Processing triggers"* ]]; then
      detected_percent=77; detected_label="Finalizowanie pakietów systemowych"
    elif [[ "$snapshot" == *"Installing dependencies"* ]]; then
      detected_percent=5; detected_label="Przygotowywanie pakietów i Dockera"
    fi
  elif [[ "$action" == "blueprint-uninstall" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: panel update complete"* ]]; then
      detected_percent=98; detected_label="Blueprint usunięty"
    elif [[ "$snapshot" == *"BlackHost stage: panel update online"* ]]; then
      detected_percent=96; detected_label="Uruchamianie czystego Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update queue"* ]]; then
      detected_percent=90; detected_label="Restart kolejki panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update ownership"* ]]; then
      detected_percent=86; detected_label="Ustawianie właściciela plików"
    elif [[ "$snapshot" == *"BlackHost stage: panel update migrations"* ]]; then
      detected_percent=78; detected_label="Weryfikacja bazy Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update cache"* ]]; then
      detected_percent=70; detected_label="Czyszczenie cache Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update composer"* ]]; then
      detected_percent=56; detected_label="Odtwarzanie zależności PHP"
    elif [[ "$snapshot" == *"BlackHost stage: panel update permissions"* ]]; then
      detected_percent=48; detected_label="Ustawianie uprawnień"
    elif [[ "$snapshot" == *"BlackHost stage: panel update extract"* ]]; then
      detected_percent=40; detected_label="Odtwarzanie czystego Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint uninstall remove"* ]]; then
      detected_percent=32; detected_label="Usuwanie plików Blueprinta"
    elif [[ "$snapshot" == *"BlackHost stage: panel update clean"* ]]; then
      detected_percent=28; detected_label="Usuwanie zmodyfikowanych plików"
    elif [[ "$snapshot" == *"BlackHost stage: panel update maintenance"* ]]; then
      detected_percent=24; detected_label="Włączanie trybu konserwacji"
    elif [[ "$snapshot" == *"BlackHost stage: panel update validate"* ]]; then
      detected_percent=16; detected_label="Weryfikacja czystego Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update download"* ]]; then
      detected_percent=8; detected_label="Pobieranie czystego Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint uninstall preflight"* ]]; then
      detected_percent=4; detected_label="Sprawdzanie Panelu i narzędzi"
    fi
  elif [[ "$action" == "blueprint-install" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: blueprint complete"* ]]; then
      detected_percent=98; detected_label="Blueprint gotowy"
    elif [[ "$snapshot" == *"Rebuilding panel assets"* ]]; then
      detected_percent=96; detected_label="Przebudowa frontendu panelu"
    elif [[ "$snapshot" == *"Changing Pterodactyl file ownership"* ]]; then
      detected_percent=94; detected_label="Ustawianie uprawnień plików"
    elif [[ "$snapshot" == *"Restarting queue workers"* ]]; then
      detected_percent=92; detected_label="Restart kolejki panelu"
    elif [[ "$snapshot" == *"Flushing cache"* ]]; then
      detected_percent=90; detected_label="Odświeżanie pamięci podręcznej"
    elif [[ "$snapshot" == *"Seeding Blueprint database records"* ]]; then
      detected_percent=88; detected_label="Konfiguracja bazy Blueprinta"
    elif [[ "$snapshot" == *"Running database migrations"* ]]; then
      detected_percent=85; detected_label="Migracje bazy danych"
    elif [[ "$snapshot" == *"maintenance mode"* ]]; then
      detected_percent=82; detected_label="Tryb konserwacji panelu"
    elif [[ "$snapshot" == *"Linking directories and filesystems"* ]]; then
      detected_percent=80; detected_label="Łączenie plików Blueprinta"
    elif [[ "$snapshot" == *"Searching and validating framework dependencies"* ]]; then
      detected_percent=76; detected_label="Weryfikacja zależności"
    elif [[ "$snapshot" == *"Installing node modules"* ]]; then
      detected_percent=72; detected_label="Instalacja modułów Node.js"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint framework"* ]]; then
      detected_percent=68; detected_label="Instalacja frameworka Blueprint"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint configure"* ]]; then
      detected_percent=64; detected_label="Konfiguracja Blueprinta"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint extract"* ]]; then
      detected_percent=60; detected_label="Rozpakowywanie Blueprinta"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint verify"* ]]; then
      detected_percent=55; detected_label="Weryfikacja pobranego wydania"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint download"* ]]; then
      detected_percent=48; detected_label="Pobieranie Blueprinta"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint yarn"* ]]; then
      detected_percent=42; detected_label="Instalacja Yarn"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint node install"* ]]; then
      detected_percent=34; detected_label="Instalacja Node.js 22"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint node repository"* ]]; then
      detected_percent=24; detected_label="Konfiguracja repozytorium Node.js"
    elif [[ "$snapshot" == *"BlackHost stage: blueprint dependencies"* ]]; then
      detected_percent=8; detected_label="Instalacja wymaganych pakietów"
    fi
  elif [[ "$action" == "nginx-install" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: nginx complete"* ]]; then
      detected_percent=98; detected_label="Nginx gotowy"
    elif [[ "$snapshot" == *"BlackHost stage: nginx service"* ]]; then
      detected_percent=88; detected_label="Uruchamianie usługi Nginx"
    elif [[ "$snapshot" == *"BlackHost stage: nginx configuration"* ]]; then
      detected_percent=78; detected_label="Sprawdzanie konfiguracji Nginx"
    elif ((package_total > 0 && package_configured > 0)); then
      detected_percent=$(progress_count_percent 50 26 "$package_configured" "$package_total")
      detected_label="Konfigurowanie pakietów (${package_configured}/${package_total})"
    elif ((package_total > 0 && package_unpacked > 0)); then
      detected_percent=$(progress_count_percent 26 24 "$package_unpacked" "$package_total")
      detected_label="Rozpakowywanie pakietów (${package_unpacked}/${package_total})"
    elif ((package_total > 0 && package_downloaded > 0)); then
      detected_percent=$(progress_count_percent 10 16 "$package_downloaded" "$package_total")
      detected_label="Pobieranie pakietów (${package_downloaded}/${package_total})"
    elif [[ "$snapshot" == *"BlackHost stage: nginx packages"* ]]; then
      detected_percent=9; detected_label="Instalacja pakietu Nginx"
    elif [[ "$snapshot" == *"BlackHost stage: nginx repositories"* ]]; then
      detected_percent=5; detected_label="Aktualizacja listy pakietów"
    fi
  elif [[ "$action" == "nginx-uninstall" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: nginx uninstall complete"* ]]; then
      detected_percent=98; detected_label="Nginx usunięty"
    elif [[ "$snapshot" == *"BlackHost stage: nginx configuration cleanup"* ]]; then
      detected_percent=82; detected_label="Obsługa konfiguracji Nginx"
    elif [[ "$snapshot" == *"BlackHost stage: nginx remove package"* ]]; then
      detected_percent=52; detected_label="Usuwanie pakietów Nginx"
    elif [[ "$snapshot" == *"BlackHost stage: nginx stop"* ]]; then
      detected_percent=30; detected_label="Zatrzymywanie usługi Nginx"
    fi
  elif [[ "$action" == "pterodactyl-wings-update" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: wings update complete"* ]]; then
      detected_percent=98; detected_label="Wings zaktualizowane"
    elif [[ "$snapshot" == *"BlackHost stage: wings update verify"* ]]; then
      detected_percent=94; detected_label="Sprawdzanie wersji i usługi"
    elif [[ "$snapshot" == *"BlackHost stage: wings update restart"* ]]; then
      detected_percent=84; detected_label="Uruchamianie Wings"
    elif [[ "$snapshot" == *"BlackHost stage: wings update install"* ]]; then
      detected_percent=66; detected_label="Podmiana binarki Wings"
    elif [[ "$snapshot" == *"BlackHost stage: wings update stop"* ]]; then
      detected_percent=52; detected_label="Zatrzymywanie Wings"
    elif [[ "$snapshot" == *"BlackHost stage: wings update validate"* ]]; then
      detected_percent=34; detected_label="Sprawdzanie pobranej wersji"
    elif [[ "$snapshot" == *"BlackHost stage: wings update download"* ]]; then
      detected_percent=12; detected_label="Pobieranie Wings"
    fi
  elif [[ "$action" == "pterodactyl-panel-update" ]]; then
    if [[ "$snapshot" == *"BlackHost stage: panel update complete"* ]]; then
      detected_percent=98; detected_label="Panel zaktualizowany"
    elif [[ "$snapshot" == *"BlackHost stage: panel update online"* ]]; then
      detected_percent=96; detected_label="Wyłączanie trybu konserwacji"
    elif [[ "$snapshot" == *"BlackHost stage: panel update blueprint"* ]]; then
      detected_percent=92; detected_label="Ponowne nakładanie Blueprinta"
    elif [[ "$snapshot" == *"BlackHost stage: panel update queue"* ]]; then
      detected_percent=88; detected_label="Restart kolejki panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update ownership"* ]]; then
      detected_percent=84; detected_label="Ustawianie właściciela plików"
    elif [[ "$snapshot" == *"BlackHost stage: panel update migrations"* ]]; then
      detected_percent=76; detected_label="Migracje i aktualizacja eggów"
    elif [[ "$snapshot" == *"BlackHost stage: panel update cache"* ]]; then
      detected_percent=68; detected_label="Czyszczenie cache panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update composer"* ]]; then
      detected_percent=50; detected_label="Aktualizacja zależności PHP"
    elif [[ "$snapshot" == *"BlackHost stage: panel update permissions"* ]]; then
      detected_percent=42; detected_label="Ustawianie uprawnień"
    elif [[ "$snapshot" == *"BlackHost stage: panel update extract"* ]]; then
      detected_percent=34; detected_label="Rozpakowywanie plików Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update maintenance"* ]]; then
      detected_percent=26; detected_label="Włączanie trybu konserwacji"
    elif [[ "$snapshot" == *"BlackHost stage: panel update validate"* ]]; then
      detected_percent=18; detected_label="Weryfikacja archiwum Panelu"
    elif [[ "$snapshot" == *"BlackHost stage: panel update download"* ]]; then
      detected_percent=8; detected_label="Pobieranie najnowszego Panelu"
    fi
  elif [[ "$action" == "pterodactyl-panel-repair" ]]; then
    if [[ "$snapshot" == *"Etap: certyfikat"* ]]; then
      detected_percent=90; detected_label="Konfiguracja certyfikatu SSL"
    elif [[ "$snapshot" == *"Etap: nginx"* ]]; then
      detected_percent=68; detected_label="Konfiguracja Nginx"
    elif [[ "$snapshot" == *"Etap: pteroq"* ]]; then
      detected_percent=42; detected_label="Uruchamianie kolejki"
    elif [[ "$snapshot" == *"Etap: cron"* ]]; then
      detected_percent=18; detected_label="Konfiguracja zadań cron"
    fi
  elif [[ "$action" == "pterodactyl-panel-uninstall" ]]; then
    if [[ "$snapshot" == *"Removed services"* ]]; then
      detected_percent=96; detected_label="Usługi panelu usunięte"
    elif [[ "$snapshot" == *"Removing services"* ]]; then
      detected_percent=82; detected_label="Usuwanie usług panelu"
    elif [[ "$snapshot" == *"Handled database"* ]]; then
      detected_percent=76; detected_label="Operacje na bazie zakończone"
    elif [[ "$snapshot" == *"Removing database"* ]]; then
      detected_percent=62; detected_label="Usuwanie bazy i użytkownika"
    elif [[ "$snapshot" == *"Removed cron jobs"* ]]; then
      detected_percent=55; detected_label="Zadania cron usunięte"
    elif [[ "$snapshot" == *"Removing cron jobs"* ]]; then
      detected_percent=42; detected_label="Usuwanie zadań cron"
    elif [[ "$snapshot" == *"Removed panel files"* ]]; then
      detected_percent=35; detected_label="Pliki panelu usunięte"
    elif [[ "$snapshot" == *"Removing panel files"* ]]; then
      detected_percent=16; detected_label="Usuwanie plików panelu"
    fi
  elif [[ "$action" == "pterodactyl-wings-uninstall" ]]; then
    if [[ "$snapshot" == *"Removed wings files"* ]]; then
      detected_percent=96; detected_label="Wings i dane usunięte"
    elif [[ "$snapshot" == *"Removing wings files"* ]]; then
      detected_percent=68; detected_label="Usuwanie Wings i danych serwerów"
    elif [[ "$snapshot" == *"Removed docker containers"* ]]; then
      detected_percent=58; detected_label="Zasoby Dockera usunięte"
    elif [[ "$snapshot" == *"Removing docker containers"* ]]; then
      detected_percent=18; detected_label="Czyszczenie zasobów Dockera"
    fi
  fi

  ((detected_percent < current_percent)) && detected_percent=$current_percent
  printf '%s|%s\n' "$detected_percent" "$detected_label"
}

progress_render() {
  local percent=$1 label=$2 elapsed=$3 width label_width label_padding filled_count empty_count
  local filled empty fill_char="#" empty_char="-" content_width=${BH_CONTENT_WIDTH:-68}
  local counter_suffix prefix_length
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  width=20
  ((content_width < 68)) && width=$((content_width - 48))
  ((width < 10)) && width=10
  label_width=$((content_width - width - 15))
  ((label_width < 10)) && label_width=10
  if ((${#label} > label_width)); then
    if [[ "$label" =~ (\([0-9]+/[0-9]+\))$ ]]; then
      counter_suffix=${BASH_REMATCH[1]}
      prefix_length=$((label_width - ${#counter_suffix} - 4))
      if ((prefix_length > 0)); then
        label="${label:0:prefix_length}... ${counter_suffix}"
      else
        label="${label:0:label_width-3}..."
      fi
    else
      label="${label:0:label_width-3}..."
    fi
  fi
  label_padding=$((label_width - ${#label}))
  [[ "${BH_UNICODE:-false}" == true ]] && fill_char="█" && empty_char="░"
  filled_count=$((percent * width / 100))
  empty_count=$((width - filled_count))
  printf -v filled '%*s' "$filled_count" ''
  filled=${filled// /$fill_char}
  printf -v empty '%*s' "$empty_count" ''
  empty=${empty// /$empty_char}

  printf '\r%*s%s[%s%s]%s %3d%%  %s%*s %02d:%02d\033[K' \
    "$BH_LEFT_PAD" '' "$BH_BLUE" "$filled" "$empty" "$BH_RESET" "$percent" \
    "$label" "$label_padding" '' "$((elapsed / 60))" "$((elapsed % 60))"
}

progress_refresh_console() {
  local title=$1 log_file=$2
  [[ "${BH_SCREEN_CLEAR:-false}" == true ]] || return 0
  ui_refresh
  ui_section "$title"
  ui_info "Pełny log: $log_file"
  printf '\n'
}

run_with_spinner() {
  local label=$1
  shift
  ui_safe_text "$label"
  label=$BH_SAFE_TEXT
  if [[ ! -t 1 ]]; then
    "$@"
    return $?
  fi

  local pid status frame_index=0 frames='|/-\'
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%*s%s%s%s  %s\033[K' \
      "$BH_LEFT_PAD" '' "$BH_BLUE" "${frames:frame_index%4:1}" "$BH_RESET" "$label"
    frame_index=$((frame_index + 1))
    sleep 0.15
  done
  wait "$pid" || status=$?
  printf '\r\033[2K'
  return "${status:-0}"
}

show_log_excerpt() {
  local log_file=$1
  ui_section "OSTATNI FRAGMENT LOGU"
  tail -n 40 "$log_file" 2>/dev/null \
    | sed -E $'s/\x1B\[[0-9;]*[[:alpha:]]//g; /^[[:space:]]*$/d' \
    | tail -n 8 \
    | while IFS= read -r line; do
        ui_safe_text "$line"
        line=$BH_SAFE_TEXT
        ui_indent
        printf '%s%s%s\n' "$BH_DIM" "$line" "$BH_RESET"
      done
}

run_with_progress() {
  local action=$1
  shift
  local log_file="${BLACKHOST_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-${action}.log"
  BLACKHOST_LAST_LOG=$log_file

  if [[ ! -t 1 || "${BLACKHOST_RAW_LOGS:-0}" == "1" ]]; then
    ui_info "Log operacji: $log_file"
    "$@" 2>&1 | tee -a "$log_file"
    return ${PIPESTATUS[0]}
  fi

  local progress_title="POSTĘP INSTALACJI"
  local initial_label="Uruchamianie instalatora"
  local completion_label="Instalacja zakończona"
  local interrupted_message="Instalacja została przerwana."
  case "$action" in
    *-uninstall)
      progress_title="POSTĘP ODINSTALOWANIA"
      initial_label="Uruchamianie odinstalowywania"
      completion_label="Odinstalowanie zakończone"
      interrupted_message="Odinstalowanie zostało przerwane."
      ;;
    *-repair)
      progress_title="POSTĘP NAPRAWY"
      initial_label="Uruchamianie naprawy"
      completion_label="Naprawa zakończona"
      interrupted_message="Naprawa została przerwana."
      ;;
    *-update)
      progress_title="POSTĘP AKTUALIZACJI"
      initial_label="Uruchamianie aktualizacji"
      completion_label="Aktualizacja zakończona"
      interrupted_message="Aktualizacja została przerwana."
      ;;
  esac

  local pid status percent=3 label="$initial_label" stage
  local started_at=$SECONDS interrupted=false
  : >"$log_file"
  ui_section "$progress_title"
  ui_info "Pełny log: $log_file"
  printf '\n'

  "$@" </dev/null >"$log_file" 2>&1 &
  pid=$!
  trap 'interrupted=true; kill "$pid" 2>/dev/null || true' INT TERM HUP

  while kill -0 "$pid" 2>/dev/null; do
    stage=$(progress_stage "$action" "$log_file" "$percent" "$label")
    percent=${stage%%|*}
    label=${stage#*|}
    progress_refresh_console "$progress_title" "$log_file"
    progress_render "$percent" "$label" "$((SECONDS - started_at))"
    sleep 0.25
  done

  wait "$pid" || status=$?
  status=${status:-0}
  trap 'exit 130' INT TERM HUP

  if [[ "$interrupted" == true ]]; then
    progress_refresh_console "$progress_title" "$log_file"
    printf '\r\033[2K'
    ui_warn "$interrupted_message Log: $log_file"
    return 130
  fi

  if [[ "$status" -eq 0 ]]; then
    progress_refresh_console "$progress_title" "$log_file"
    progress_render 100 "$completion_label" "$((SECONDS - started_at))"
    printf '\n'
    return 0
  fi

  progress_refresh_console "$progress_title" "$log_file"
  printf '\r\033[2K'
  ui_error "Instalator zakończył się kodem $status."
  show_log_excerpt "$log_file"
  ui_info "Pełny log: $log_file"
  return "$status"
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_db_identifier() {
  [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

valid_fqdn() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_ipv4() {
  local address=$1 octet
  local -a octets
  IFS=. read -r -a octets <<<"$address"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

valid_timezone() {
  [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] && [[ -f "/usr/share/zoneinfo/$1" ]]
}

json_escape() {
  local value=${1:-} output="" char escaped code i
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    case "$char" in
      '"') output+='\"' ;;
      '\') output+='\\' ;;
      $'\b') output+='\b' ;;
      $'\f') output+='\f' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        printf -v code '%d' "'$char"
        if ((code < 32)); then
          printf -v escaped '\\u%04x' "$code"
          output+=$escaped
        else
          output+=$char
        fi
        ;;
    esac
  done
  printf '%s' "$output"
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

write_state() {
  local component=$1
  shift
  local state_file="${BLACKHOST_STATE_DIR}/${component}.state"
  {
    printf 'installed_at=%q\n' "$(date --iso-8601=seconds)"
    printf 'cli_version=%q\n' "$BLACKHOST_VERSION"
    printf '%s\n' "$@"
  } >"$state_file"
  chmod 600 "$state_file"
}

remove_state() {
  local component=$1
  rm -f -- "${BLACKHOST_STATE_DIR}/${component}.state" 2>/dev/null || true
}
