#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

BLACKHOST_PROVISION_INSTALLATION_ID=""
BLACKHOST_PROVISION_EXECUTION_TOKEN=""
BLACKHOST_API_URL="${BLACKHOST_API_URL:-https://dash.blackhost.pl}"
BLACKHOST_PROVISION_INTERRUPTED=false

provision_json_get() {
  local json=$1 path=$2
  if command -v jq >/dev/null 2>&1; then
    jq -r "${path} // empty" <<<"$json" 2>/dev/null
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    path = [p for p in sys.argv[1].split(".") if p]
    cur = data
    for key in path:
        if isinstance(cur, dict) and key in cur:
            cur = cur[key]
        else:
            cur = None
            break
    if cur is not None and cur != "":
        if isinstance(cur, bool):
            print("true" if cur else "false")
        elif isinstance(cur, (dict, list)):
            print(json.dumps(cur))
        else:
            print(str(cur))
except Exception:
    sys.exit(1)
' "$path" <<<"$json" 2>/dev/null
    return $?
  fi

  return 127
}

provision_json_valid() {
  local json=$1
  if command -v jq >/dev/null 2>&1; then
    jq -e . >/dev/null 2>&1 <<<"$json"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; json.load(sys.stdin)' <<<"$json" 2>/dev/null
  else
    return 127
  fi
}

provision_require_json_parser() {
  if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    ui_error "Wymagany jest parser JSON: jq lub python3."
    return 1
  fi
}

provision_json_boolean() {
  local json=$1 path=$2 default_value=$3 value
  value=$(provision_json_get "$json" "$path") || return 1
  value=$(tr '[:upper:]' '[:lower:]' <<<"$value")
  [[ -z "$value" ]] && value=$default_value
  [[ "$value" == true || "$value" == false ]] || return 1
  printf '%s' "$value"
}

provision_valid_safe_text() {
  local value=$1 max_length=${2:-255}
  [[ -n "$value" && ${#value} -le $max_length && ! "$value" =~ [[:cntrl:]] ]]
}

provision_valid_secret() {
  local value=$1
  provision_valid_safe_text "$value" 256 \
    && [[ ${#value} -ge 12 && "$value" != *"'"* && "$value" != *'\\'* ]]
}

provision_valid_api_url() {
  local url=$1 rest authority
  if [[ "$url" == https://* ]]; then
    rest=${url#https://}
    authority=${rest%%/*}
    [[ -n "$authority" && "$authority" != *'@'* \
      && "$url" != *$'\n'* && "$url" != *$'\r'* && "$url" != *$'\t'* \
      && "$url" != *' '* ]]
    return $?
  fi
  [[ "$url" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]]
}

provision_config_error() {
  local message=$1
  ui_error "$message"
  provision_fail "INVALID_CONFIGURATION" "$message"
  return 1
}

provision_assign_boolean() {
  local variable_name=$1 json=$2 path=$3 default_value=$4 error_message=$5 value
  value=$(provision_json_boolean "$json" "$path" "$default_value") || {
    provision_config_error "$error_message"
    return 1
  }
  printf -v "$variable_name" '%s' "$value"
  export "$variable_name"
}

provision_assign_value() {
  local variable_name=$1 json=$2 path=$3 value
  value=$(provision_json_get "$json" "$path") || {
    provision_config_error "Nie udało się odczytać pola konfiguracji: $path"
    return 1
  }
  printf -v "$variable_name" '%s' "$value"
  export "$variable_name"
}

provision_operation_fail() {
  local code=$1 message=$2
  if [[ "$BLACKHOST_PROVISION_INTERRUPTED" == true ]]; then
    provision_fail "PROCESS_INTERRUPTED" "Operacja została przerwana sygnałem systemowym."
  else
    provision_fail "$code" "$message"
  fi
}

provision_curl() {
  local method=$1 url=$2 token=${3:-} data=${4:-}
  local args=(-sS -m 30 --proto '=https,http' --tlsv1.2)

  if ! provision_valid_api_url "$url"; then
    ui_error "Adres API musi używać HTTPS (HTTP jest dozwolone tylko dla localhost lub 127.0.0.1): $url"
    return 1
  fi

  args+=(-X "$method")
  args+=(-H 'Content-Type: application/json')
  args+=(-H "User-Agent: BlackHostCLI/${BLACKHOST_VERSION}")
  args+=(-H 'ngrok-skip-browser-warning: true')
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")
  [[ -n "$data" ]] && args+=(-d "$data")

  curl "${args[@]}" "$url"
}

BLACKHOST_HIGHEST_PROGRESS=0

provision_report_progress() {
  local progress=$1 stage=$2
  [[ -z "$BLACKHOST_PROVISION_INSTALLATION_ID" || -z "$BLACKHOST_PROVISION_EXECUTION_TOKEN" ]] && return 0

  if ((progress < BLACKHOST_HIGHEST_PROGRESS)); then
    progress=$BLACKHOST_HIGHEST_PROGRESS
  else
    BLACKHOST_HIGHEST_PROGRESS=$progress
  fi

  local endpoint="${BLACKHOST_API_URL}/api/v1/provisioning/${BLACKHOST_PROVISION_INSTALLATION_ID}/progress"
  local payload
  payload=$(printf '{"progress":%d,"stage":"%s"}' "$progress" "$(json_escape "$stage")")

  provision_curl POST "$endpoint" "$BLACKHOST_PROVISION_EXECUTION_TOKEN" "$payload" >/dev/null 2>&1 || true
}

provision_complete() {
  [[ -z "$BLACKHOST_PROVISION_INSTALLATION_ID" || -z "$BLACKHOST_PROVISION_EXECUTION_TOKEN" ]] && return 0
  local endpoint="${BLACKHOST_API_URL}/api/v1/provisioning/${BLACKHOST_PROVISION_INSTALLATION_ID}/complete"
  provision_curl POST "$endpoint" "$BLACKHOST_PROVISION_EXECUTION_TOKEN" '{}' >/dev/null 2>&1 || true
}

provision_fail() {
  local code=${1:-UNKNOWN_ERROR} message=${2:-Instalacja nie powiodła się.}
  [[ -z "$BLACKHOST_PROVISION_INSTALLATION_ID" || -z "$BLACKHOST_PROVISION_EXECUTION_TOKEN" ]] && return 0

  local endpoint="${BLACKHOST_API_URL}/api/v1/provisioning/${BLACKHOST_PROVISION_INSTALLATION_ID}/fail"
  local payload
  payload=$(printf '{"error_code":"%s","error_message":"%s"}' \
    "$(json_escape "$code")" "$(json_escape "$message")")

  provision_curl POST "$endpoint" "$BLACKHOST_PROVISION_EXECUTION_TOKEN" "$payload" >/dev/null 2>&1 || true
}

provision_run_with_progress() {
  local action=$1
  shift
  local log_file="${BLACKHOST_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-${action}.log"
  BLACKHOST_LAST_LOG=$log_file
  : >"$log_file"

  local progress_title="POSTĘP INSTALACJI"
  [[ "$action" == *uninstall* ]] && progress_title="POSTĘP DEINSTALACJI"
  local pid status percent=5 label="Inicjalizacja instalacji" stage interrupted=false
  [[ "$action" == *uninstall* ]] && label="Inicjalizacja deinstalacji"
  ((percent < BLACKHOST_HIGHEST_PROGRESS)) && percent=$BLACKHOST_HIGHEST_PROGRESS
  local started_at=$SECONDS last_reported_percent=0 last_reported_label=""

  "$@" </dev/null >"$log_file" 2>&1 &
  pid=$!
  BLACKHOST_PROVISION_INTERRUPTED=false
  trap 'interrupted=true; BLACKHOST_PROVISION_INTERRUPTED=true; kill "$pid" 2>/dev/null || true' INT TERM HUP

  while kill -0 "$pid" 2>/dev/null; do
    stage=$(progress_stage "$action" "$log_file" "$percent" "$label")
    percent=${stage%%|*}
    label=${stage#*|}

    if ((percent != last_reported_percent)) || [[ "$label" != "$last_reported_label" ]]; then
      last_reported_percent=$percent
      last_reported_label=$label
      provision_report_progress "$percent" "$label"
    fi

    if [[ -t 1 && "${BLACKHOST_RAW_LOGS:-0}" != "1" ]]; then
      progress_refresh_console "$progress_title" "$log_file"
      progress_render "$percent" "$label" "$((SECONDS - started_at))"
    fi
    sleep 0.5
  done

  wait "$pid" || status=$?
  status=${status:-0}
  trap 'provision_fail "PROCESS_INTERRUPTED" "Operacja została przerwana sygnałem systemowym."; exit 130' INT TERM HUP

  if [[ "$interrupted" == true ]]; then
    return 130
  fi

  if ((status == 0)); then
    provision_report_progress 99 "Finalizowanie konfiguracji usługi"
  fi

  return "$status"
}

blackhost_provision_run() {
  local token_arg="" token_file="" claim_token=""

  while (($# > 0)); do
    case "$1" in
      --token)
        (($# >= 2)) || {
          ui_error "Opcja --token wymaga wartości."
          return 1
        }
        token_arg=$2
        shift 2
        ;;
      --token-file)
        (($# >= 2)) || {
          ui_error "Opcja --token-file wymaga ścieżki."
          return 1
        }
        token_file=$2
        shift 2
        ;;
      --api-url)
        (($# >= 2)) || {
          ui_error "Opcja --api-url wymaga adresu."
          return 1
        }
        BLACKHOST_API_URL=$2
        shift 2
        ;;
      *)
        ui_error "Nieznana opcja provision: $1"
        return 1
        ;;
    esac
  done

  if [[ -n "$token_file" && -n "$token_arg" ]]; then
    ui_error "Użyj tylko jednej opcji: --token albo --token-file."
    return 1
  fi

  BLACKHOST_API_URL=${BLACKHOST_API_URL%/}
  if ! provision_valid_api_url "$BLACKHOST_API_URL"; then
    ui_error "Nieprawidłowy adres API. Wymagany jest HTTPS; HTTP działa wyłącznie dla localhost lub 127.0.0.1."
    return 1
  fi

  export HOME="${HOME:-/root}"
  export COMPOSER_HOME="${COMPOSER_HOME:-/root/.config/composer}"
  export COMPOSER_ALLOW_SUPERUSER=1
  export DEBIAN_FRONTEND="noninteractive"
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

  require_linux || return 1
  require_root || return 1
  require_commands curl || return 1
  provision_require_json_parser || return 1
  ensure_runtime_dirs || return 1
  acquire_operation_lock || return 1

  if [[ -n "$token_file" ]]; then
    if [[ "$token_file" == "/dev/stdin" || "$token_file" == "-" ]]; then
      claim_token=$(cat)
    elif [[ -r "$token_file" || -e "$token_file" || -p "$token_file" || "$token_file" == /dev/fd/* || "$token_file" == /proc/* ]]; then
      claim_token=$(cat "$token_file" 2>/dev/null || true)
      if [[ -z "$claim_token" ]]; then
        ui_error "Nie udało się odczytać zawartości z: $token_file"
        return 1
      fi
      if [[ -f "$token_file" && "$token_file" != /dev/* && "$token_file" != /proc/* ]]; then
        rm -f -- "$token_file" 2>/dev/null || true
      fi
    else
      ui_error "Plik tokenu nie istnieje lub brak uprawnień do odczytu: $token_file"
      return 1
    fi
  elif [[ -n "$token_arg" ]]; then
    claim_token=$token_arg
  else
    ui_error "Wymagany jest parametr --token <wartość> lub --token-file <ścieżka>."
    return 1
  fi

  claim_token=${claim_token//$'\r'/}
  claim_token=${claim_token//$'\n'/}
  if [[ ${#claim_token} -lt 16 || ${#claim_token} -gt 4096 \
    || ! "$claim_token" =~ ^bhj_[A-Za-z0-9._~-]+$ ]]; then
    ui_error "Nieprawidłowy token claim."
    return 1
  fi

  ui_info "Pobieranie konfiguracji zadania z Dashboardu..."
  local claim_endpoint="${BLACKHOST_API_URL}/api/v1/provisioning/claim"
  local claim_response
  claim_response=$(provision_curl POST "$claim_endpoint" "$claim_token" '{}') || {
    ui_error "Nie udało się połączyć z API Dashboardu: $claim_endpoint"
    return 1
  }
  if ! provision_json_valid "$claim_response"; then
    ui_error "API Dashboardu zwróciło nieprawidłowy JSON."
    return 1
  fi

  local success
  success=$(tr '[:upper:]' '[:lower:]' <<<"$(provision_json_get "$claim_response" ".success")")
  if [[ "$success" != "true" ]]; then
    local err_msg
    err_msg=$(provision_json_get "$claim_response" ".error")
    if [[ -z "$err_msg" ]]; then
      err_msg=$(tr -d '\r\n' <<<"$claim_response" | head -c 250)
    fi
    ui_error "Błąd claim z API: ${err_msg:-Brak odpowiedzi}"
    return 1
  fi

  BLACKHOST_PROVISION_INSTALLATION_ID=$(provision_json_get "$claim_response" ".installation.id")
  BLACKHOST_PROVISION_EXECUTION_TOKEN=$(provision_json_get "$claim_response" ".execution_token")
  local app
  app=$(provision_json_get "$claim_response" ".installation.application")

  if [[ ! "$BLACKHOST_PROVISION_INSTALLATION_ID" =~ ^[A-Za-z0-9_-]{1,128}$ \
    || ${#BLACKHOST_PROVISION_EXECUTION_TOKEN} -lt 16 \
    || ${#BLACKHOST_PROVISION_EXECUTION_TOKEN} -gt 4096 \
    || "$BLACKHOST_PROVISION_EXECUTION_TOKEN" =~ [[:space:]] \
    || -z "$app" ]]; then
    ui_error "Otrzymano niekompletną odpowiedź z API provisioning."
    return 1
  fi

  case "$app" in
    pterodactyl-panel|pterodactyl-wings|blueprint|nginx|phpmyadmin) ;;
    *)
      provision_config_error "Nieobsługiwany typ aplikacji: $app"
      return 1
      ;;
  esac

  local action
  action=$(provision_json_get "$claim_response" ".installation.configuration.action")
  [[ -z "$action" || "$action" == "null" ]] && action="install"
  if [[ "$action" != install && "$action" != uninstall ]]; then
    provision_config_error "Nieobsługiwana akcja provisioning: $action"
    return 1
  fi

  trap 'provision_fail "PROCESS_INTERRUPTED" "Operacja została przerwana sygnałem systemowym."; exit 130' INT TERM HUP

  if [[ "$action" == "uninstall" ]]; then
    ui_info "Rozpoczynanie odinstalowywania: $app (ID: $BLACKHOST_PROVISION_INSTALLATION_ID)"
    provision_report_progress 5 "Inicjalizacja odinstalowywania ${app}"

    case "$app" in
      pterodactyl-panel)
        provision_assign_boolean PTERO_REMOVE_DATABASE "$claim_response" \
          ".installation.configuration.remove_database" false \
          "Pole remove_database musi mieć wartość true albo false." || return 1
        provision_assign_boolean PTERO_REMOVE_DB_USER "$claim_response" \
          ".installation.configuration.remove_db_user" false \
          "Pole remove_db_user musi mieć wartość true albo false." || return 1
        provision_assign_value PTERO_DATABASE_TO_REMOVE "$claim_response" \
          ".installation.configuration.db_name" || return 1
        provision_assign_value PTERO_DB_USER_TO_REMOVE "$claim_response" \
          ".installation.configuration.db_user" || return 1
        if [[ -z "$PTERO_DATABASE_TO_REMOVE" || "$PTERO_DATABASE_TO_REMOVE" == "null" ]]; then
          if [[ "$PTERO_REMOVE_DATABASE" == true ]]; then
            PTERO_DATABASE_TO_REMOVE=$(pterodactyl_read_panel_env_value DB_DATABASE "")
            export PTERO_DATABASE_TO_REMOVE
          else
            export PTERO_DATABASE_TO_REMOVE="panel"
          fi
        fi
        if [[ -z "$PTERO_DB_USER_TO_REMOVE" || "$PTERO_DB_USER_TO_REMOVE" == "null" ]]; then
          if [[ "$PTERO_REMOVE_DB_USER" == true ]]; then
            PTERO_DB_USER_TO_REMOVE=$(pterodactyl_read_panel_env_value DB_USERNAME "")
            export PTERO_DB_USER_TO_REMOVE
          else
            export PTERO_DB_USER_TO_REMOVE="pterodactyl"
          fi
        fi
        if ! valid_db_identifier "$PTERO_DATABASE_TO_REMOVE"; then
          provision_config_error "Nieprawidłowa nazwa bazy danych do usunięcia."
          return 1
        fi
        if ! valid_db_identifier "$PTERO_DB_USER_TO_REMOVE"; then
          provision_config_error "Nieprawidłowa nazwa użytkownika bazy do usunięcia."
          return 1
        fi

        provision_report_progress 10 "Pobieranie oficjalnego deinstalatora Pterodactyl"
        pterodactyl_fetch_upstream || {
          provision_fail "DOWNLOAD_FAILED" "Nie udało się pobrać deinstalatora Pterodactyl."
          return 1
        }
        pterodactyl_prepare_managed_uninstaller || {
          pterodactyl_cleanup_upstream
          provision_fail "PREPARE_FAILED" "Nie udało się przygotować bezpiecznego deinstalatora Pterodactyl."
          return 1
        }
        export BLACKHOST_DATABASE_MODE="managed"
        provision_report_progress 20 "Usuwanie usług, bazy danych i plików Panelu"
        if ! provision_run_with_progress "pterodactyl-panel-uninstall" pterodactyl_uninstall_panel_impl; then
          pterodactyl_cleanup_upstream
          provision_operation_fail "UNINSTALL_FAILED" "Odinstalowywanie Panelu zakończyło się błędem."
          return 1
        fi
        pterodactyl_cleanup_upstream
        remove_state pterodactyl-panel 2>/dev/null || true
        ;;

      pterodactyl-wings)
        provision_report_progress 10 "Przygotowywanie procesu usuwania Wings"
        pterodactyl_fetch_upstream || {
          provision_fail "DOWNLOAD_FAILED" "Nie udało się pobrać deinstalatora Wings."
          return 1
        }
        provision_report_progress 20 "Usuwanie Wings, kontenerów Dockera i woluminów"
        if ! provision_run_with_progress "pterodactyl-wings-uninstall" pterodactyl_uninstall_wings_impl; then
          pterodactyl_cleanup_upstream
          provision_operation_fail "UNINSTALL_FAILED" "Odinstalowywanie Wings zakończyło się błędem."
          return 1
        fi
        pterodactyl_cleanup_upstream
        remove_state pterodactyl-wings 2>/dev/null || true
        ;;

      blueprint)
        provision_report_progress 10 "Przywracanie oryginalnych plików Panelu Pterodactyl"
        if ! provision_run_with_progress "blueprint-uninstall" blueprint_uninstall_impl; then
          provision_operation_fail "UNINSTALL_FAILED" "Odinstalowywanie Blueprinta zakończyło się błędem."
          return 1
        fi
        remove_state blueprint 2>/dev/null || true
        ;;

      nginx)
        NGINX_PACKAGE_MANAGER=$(nginx_package_manager 2>/dev/null || printf 'apt')
        export NGINX_PACKAGE_MANAGER
        provision_assign_boolean NGINX_REMOVE_CONFIG "$claim_response" \
          ".installation.configuration.remove_config" false \
          "Pole remove_config musi mieć wartość true albo false." || return 1
        provision_report_progress 10 "Zatrzymywanie usługi Nginx i usuwanie pakietów"
        if ! provision_run_with_progress "nginx-uninstall" nginx_uninstall_impl; then
          provision_operation_fail "UNINSTALL_FAILED" "Odinstalowywanie Nginx zakończyło się błędem."
          return 1
        fi
        remove_state nginx 2>/dev/null || true
        ;;

      phpmyadmin)
        provision_assign_boolean PMA_REMOVE_DB_USER "$claim_response" \
          ".installation.configuration.remove_db_user" false \
          "Pole remove_db_user musi mieć wartość true albo false." || return 1
        provision_assign_boolean PMA_REMOVE_CERT "$claim_response" \
          ".installation.configuration.remove_certificate" false \
          "Pole remove_certificate musi mieć wartość true albo false." || return 1
        provision_assign_value PMA_DB_USER "$claim_response" \
          ".installation.configuration.db_user" || return 1
        if [[ -z "$PMA_DB_USER" || "$PMA_DB_USER" == "null" ]]; then
          PMA_DB_USER=$(phpmyadmin_state_value database_user)
          export PMA_DB_USER
        fi
        PMA_FQDN=$(phpmyadmin_fqdn)
        export PMA_FQDN
        if [[ "$PMA_REMOVE_DB_USER" == true ]] && ! valid_db_identifier "$PMA_DB_USER"; then
          provision_config_error "Nieprawidłowa nazwa użytkownika bazy phpMyAdmin."
          return 1
        fi
        [[ "$PMA_REMOVE_DB_USER" == true ]] || export PMA_DB_USER=""
        if [[ "$PMA_REMOVE_CERT" == true ]] && ! valid_fqdn "$PMA_FQDN"; then
          provision_config_error "Nie można bezpiecznie ustalić domeny certyfikatu phpMyAdmin."
          return 1
        fi

        provision_report_progress 10 "Usuwanie konfiguracji Nginx i plików phpMyAdmin"
        if ! provision_run_with_progress "phpmyadmin-uninstall" phpmyadmin_uninstall_impl; then
          provision_operation_fail "UNINSTALL_FAILED" "Odinstalowywanie phpMyAdmin zakończyło się błędem."
          return 1
        fi
        remove_state phpmyadmin 2>/dev/null || true
        ;;

      *)
        provision_fail "UNSUPPORTED_APP" "Nieobsługiwany typ aplikacji: $app"
        return 1
        ;;
    esac

    provision_report_progress 100 "Aplikacja została pomyślnie odinstalowana"
    provision_complete
    ui_success "Aplikacja $app została pomyślnie odinstalowana!"
    return 0
  fi

  ui_info "Rozpoczynanie instalacji: $app (ID: $BLACKHOST_PROVISION_INSTALLATION_ID)"
  provision_report_progress 5 "Inicjalizacja instalatora ${app}"

  case "$app" in
    pterodactyl-panel)
      provision_assign_value PTERO_FQDN "$claim_response" ".installation.configuration.fqdn" || return 1
      provision_assign_value PTERO_EMAIL "$claim_response" ".installation.configuration.email" || return 1
      provision_assign_value PTERO_ADMIN_USERNAME "$claim_response" \
        ".installation.configuration.admin_username" || return 1
      provision_assign_value PTERO_ADMIN_FIRSTNAME "$claim_response" \
        ".installation.configuration.admin_firstname" || return 1
      provision_assign_value PTERO_ADMIN_LASTNAME "$claim_response" \
        ".installation.configuration.admin_lastname" || return 1
      provision_assign_value PTERO_ADMIN_PASSWORD "$claim_response" \
        ".installation.configuration.admin_password" || return 1
      provision_assign_value PTERO_DB_NAME "$claim_response" ".installation.configuration.db_name" || return 1
      provision_assign_value PTERO_DB_USER "$claim_response" ".installation.configuration.db_user" || return 1
      provision_assign_value PTERO_DB_PASSWORD "$claim_response" \
        ".installation.configuration.db_password" || return 1
      provision_assign_value PTERO_TIMEZONE "$claim_response" ".installation.configuration.timezone" || return 1
      provision_assign_boolean PTERO_LETSENCRYPT "$claim_response" \
        ".installation.configuration.letsencrypt" false \
        "Pole letsencrypt musi mieć wartość true albo false." || return 1
      provision_assign_boolean PTERO_FIREWALL "$claim_response" \
        ".installation.configuration.firewall" false \
        "Pole firewall musi mieć wartość true albo false." || return 1
      provision_assign_boolean PTERO_TELEMETRY "$claim_response" \
        ".installation.configuration.telemetry" false \
        "Pole telemetry musi mieć wartość true albo false." || return 1
      export PTERO_ADMIN_EMAIL="$PTERO_EMAIL"
      export PTERO_ASSUME_SSL=false

      if ! valid_fqdn "$PTERO_FQDN" || ! valid_email "$PTERO_EMAIL"; then
        provision_config_error "Nieprawidłowa domena lub adres e-mail Panelu."
        return 1
      fi
      if [[ ! "$PTERO_ADMIN_USERNAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] \
        || ! provision_valid_safe_text "$PTERO_ADMIN_FIRSTNAME" 128 \
        || ! provision_valid_safe_text "$PTERO_ADMIN_LASTNAME" 128; then
        provision_config_error "Nieprawidłowe dane konta administratora Panelu."
        return 1
      fi
      if ! provision_valid_secret "$PTERO_ADMIN_PASSWORD" \
        || ! valid_db_identifier "$PTERO_DB_NAME" \
        || ! valid_db_identifier "$PTERO_DB_USER" \
        || ! provision_valid_secret "$PTERO_DB_PASSWORD" \
        || ! valid_timezone "$PTERO_TIMEZONE"; then
        provision_config_error "Nieprawidłowe dane uwierzytelniające bazy lub strefa czasowa Panelu."
        return 1
      fi

      provision_report_progress 10 "Weryfikacja wymagań wstępnych systemu"
      pterodactyl_preflight || {
        provision_fail "PREFLIGHT_FAILED" "Wymagania wstępne dla Panelu Pterodactyl nie zostały spełnione."
        return 1
      }

      provision_report_progress 20 "Pobieranie oficjalnego instalatora Pterodactyl"
      pterodactyl_fetch_upstream || {
        provision_fail "DOWNLOAD_FAILED" "Nie udało się pobrać pakietów instalatora Pterodactyl."
        return 1
      }

      provision_report_progress 25 "Wykonywanie instalacji Pterodactyl Panel"
      if ! provision_run_with_progress "pterodactyl-panel-install" pterodactyl_install_panel_impl; then
        pterodactyl_cleanup_upstream
        provision_operation_fail "INSTALL_FAILED" "Wystąpił błąd podczas instalacji komponentów Panelu."
        return 1
      fi

      pterodactyl_cleanup_upstream
      write_state pterodactyl-panel \
        "upstream_version=${PTERO_INSTALLER_VERSION}" \
        "fqdn=${PTERO_FQDN}" \
        "database=${PTERO_DB_NAME}" \
        "database_user=${PTERO_DB_USER}"
      ;;

    pterodactyl-wings)
      provision_assign_boolean WINGS_FIREWALL "$claim_response" \
        ".installation.configuration.firewall" false \
        "Pole firewall musi mieć wartość true albo false." || return 1
      provision_assign_boolean WINGS_LETSENCRYPT "$claim_response" \
        ".installation.configuration.letsencrypt" false \
        "Pole letsencrypt musi mieć wartość true albo false." || return 1
      provision_assign_value WINGS_FQDN "$claim_response" ".installation.configuration.fqdn" || return 1
      provision_assign_value WINGS_EMAIL "$claim_response" ".installation.configuration.email" || return 1
      provision_assign_boolean WINGS_DBHOST "$claim_response" \
        ".installation.configuration.configure_dbhost" false \
        "Pole configure_dbhost musi mieć wartość true albo false." || return 1
      provision_assign_boolean WINGS_DB_EXTERNAL "$claim_response" \
        ".installation.configuration.dbhost_allow_external" false \
        "Pole dbhost_allow_external musi mieć wartość true albo false." || return 1
      provision_assign_value WINGS_DB_HOST "$claim_response" ".installation.configuration.dbhost_ip" || return 1
      provision_assign_value WINGS_DB_USER "$claim_response" ".installation.configuration.dbhost_user" || return 1
      provision_assign_value WINGS_DB_PASSWORD "$claim_response" \
        ".installation.configuration.dbhost_password" || return 1
      provision_assign_boolean WINGS_DB_FIREWALL "$claim_response" \
        ".installation.configuration.dbhost_firewall" false \
        "Pole dbhost_firewall musi mieć wartość true albo false." || return 1
      [[ -n "$WINGS_DB_HOST" ]] || export WINGS_DB_HOST="127.0.0.1"
      [[ -n "$WINGS_DB_USER" ]] || export WINGS_DB_USER="pterodactyluser"

      if [[ "$WINGS_DBHOST" != true ]] \
        && { [[ "$WINGS_DB_EXTERNAL" == true ]] || [[ "$WINGS_DB_FIREWALL" == true ]]; }; then
        provision_config_error "Opcje zdalnej bazy Wings wymagają configure_dbhost=true."
        return 1
      fi

      if [[ "$WINGS_DBHOST" != true ]]; then
        export WINGS_DB_HOST="127.0.0.1"
        export WINGS_DB_USER="pterodactyluser"
        export WINGS_DB_PASSWORD=""
      elif [[ "$WINGS_DB_EXTERNAL" != true ]]; then
        export WINGS_DB_HOST="127.0.0.1"
      fi
      if [[ "$WINGS_DB_FIREWALL" == true && "$WINGS_DB_EXTERNAL" != true ]]; then
        provision_config_error "Otwarcie portu bazy Wings wymaga dbhost_allow_external=true."
        return 1
      fi

      if [[ "$WINGS_LETSENCRYPT" == true ]] \
        && { ! valid_fqdn "$WINGS_FQDN" || ! valid_email "$WINGS_EMAIL"; }; then
        provision_config_error "Nieprawidłowa domena lub adres e-mail Wings."
        return 1
      fi
      if [[ "$WINGS_DBHOST" == true ]]; then
        if ! valid_db_identifier "$WINGS_DB_USER" || ! provision_valid_secret "$WINGS_DB_PASSWORD"; then
          provision_config_error "Nieprawidłowe dane użytkownika bazy Wings."
          return 1
        fi
        if [[ "$WINGS_DB_EXTERNAL" == true ]] && ! valid_ipv4 "$WINGS_DB_HOST"; then
          provision_config_error "Nieprawidłowy adres IPv4 hosta bazy Wings."
          return 1
        fi
      fi

      provision_report_progress 15 "Przygotowanie środowiska Wings"
      pterodactyl_preflight || {
        provision_fail "PREFLIGHT_FAILED" "Wymagania wstępne dla Wings nie zostały spełnione."
        return 1
      }
      pterodactyl_fetch_upstream || {
        provision_fail "DOWNLOAD_FAILED" "Nie udało się pobrać archiwum instalatora."
        return 1
      }
      provision_report_progress 25 "Instalacja binariów Wings i konfiguracja Dockera"
      if ! provision_run_with_progress "pterodactyl-wings-install" pterodactyl_install_wings_impl; then
        pterodactyl_cleanup_upstream
        provision_operation_fail "INSTALL_FAILED" "Instalacja Pterodactyl Wings zakończyła się błędem."
        return 1
      fi
      pterodactyl_cleanup_upstream
      write_state pterodactyl-wings "upstream_version=${PTERO_INSTALLER_VERSION}"
      ;;

    blueprint)
      local bp_release
      bp_release=$(provision_json_get "$claim_response" ".installation.configuration.release")
      if [[ -z "$bp_release" || "$bp_release" == "null" ]]; then
        bp_release="$BLUEPRINT_STABLE_VERSION"
      fi
      if [[ "$bp_release" != "$BLUEPRINT_STABLE_VERSION" && "$bp_release" != "$BLUEPRINT_LATEST_VERSION" ]]; then
        provision_config_error "Nieobsługiwane wydanie Blueprint: $bp_release"
        return 1
      fi
      blueprint_use_release "$bp_release"
      provision_report_progress 15 "Sprawdzanie środowiska Blueprint (Pterodactyl Panel)"
      blueprint_preflight || {
        provision_fail "PREFLIGHT_FAILED" "Wymagania wstępne dla Blueprint nie zostały spełnione (wymagany jest zainstalowany Panel Pterodactyl)."
        return 1
      }
      provision_report_progress 25 "Kompilacja i instalacja Blueprint Framework"
      if ! provision_run_with_progress "blueprint-install" blueprint_install_impl; then
        provision_operation_fail "INSTALL_FAILED" "Instalacja Blueprinta zakończyła się błędem."
        return 1
      fi
      write_state blueprint "version=${BLUEPRINT_VERSION}" "panel_dir=${BLUEPRINT_PANEL_DIR}"
      ;;

    nginx)
      provision_report_progress 15 "Sprawdzanie menedżera pakietów Nginx"
      nginx_preflight || {
        provision_fail "PREFLIGHT_FAILED" "Wymagania wstępne dla Nginx nie zostały spełnione."
        return 1
      }
      provision_report_progress 25 "Instalacja pakietu Nginx"
      if ! provision_run_with_progress "nginx-install" nginx_install_impl; then
        provision_operation_fail "INSTALL_FAILED" "Błąd podczas instalacji Nginx."
        return 1
      fi
      local nginx_ver
      nginx_ver=$(nginx_version 2>/dev/null || printf 'unknown')
      write_state nginx "version=${nginx_ver}"
      ;;

    phpmyadmin)
      provision_assign_value PMA_FQDN "$claim_response" ".installation.configuration.fqdn" || return 1
      provision_assign_boolean PMA_LETSENCRYPT "$claim_response" \
        ".installation.configuration.letsencrypt" false \
        "Pole letsencrypt musi mieć wartość true albo false." || return 1
      provision_assign_value PMA_EMAIL "$claim_response" ".installation.configuration.email" || return 1
      provision_assign_boolean PMA_CREATE_DB_ADMIN "$claim_response" \
        ".installation.configuration.create_db_admin" false \
        "Pole create_db_admin musi mieć wartość true albo false." || return 1
      provision_assign_boolean PMA_RESET_EXISTING_DB_USER "$claim_response" \
        ".installation.configuration.reset_existing_db_user" false \
        "Pole reset_existing_db_user musi mieć wartość true albo false." || return 1
      local req_pma_user req_pma_pass
      req_pma_user=$(provision_json_get "$claim_response" ".installation.configuration.pma_db_user")
      if [[ -z "$req_pma_user" || "$req_pma_user" == "null" ]]; then
        req_pma_user=$(provision_json_get "$claim_response" ".installation.configuration.db_user")
      fi
      if [[ -z "$req_pma_user" || "$req_pma_user" == "null" ]]; then
        req_pma_user="pma_admin"
      fi
      export PMA_DB_USER="$req_pma_user"

      req_pma_pass=$(provision_json_get "$claim_response" ".installation.configuration.pma_db_password")
      if [[ -z "$req_pma_pass" || "$req_pma_pass" == "null" ]]; then
        req_pma_pass=$(provision_json_get "$claim_response" ".installation.configuration.db_password")
      fi
      if [[ -z "$req_pma_pass" || "$req_pma_pass" == "null" ]]; then
        req_pma_pass=$(openssl rand -base64 16 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)
      fi
      export PMA_DB_PASSWORD="$req_pma_pass"

      if ! valid_fqdn "$PMA_FQDN"; then
        provision_config_error "Nieprawidłowa domena phpMyAdmin."
        return 1
      fi
      if [[ "$PMA_LETSENCRYPT" == true ]] && ! valid_email "$PMA_EMAIL"; then
        provision_config_error "Nieprawidłowy adres e-mail Let's Encrypt dla phpMyAdmin."
        return 1
      fi
      if [[ "$PMA_CREATE_DB_ADMIN" == true ]]; then
        if [[ "$PMA_LETSENCRYPT" != true ]]; then
          provision_config_error "Konto administratora bazy phpMyAdmin wymaga włączonego HTTPS."
          return 1
        fi
        if ! valid_db_identifier "$PMA_DB_USER" || ! provision_valid_secret "$PMA_DB_PASSWORD"; then
          provision_config_error "Nieprawidłowe dane administratora bazy phpMyAdmin."
          return 1
        fi
      else
        export PMA_DB_USER=""
        export PMA_DB_PASSWORD=""
      fi

      provision_report_progress 15 "Weryfikacja środowiska phpMyAdmin"
      phpmyadmin_preflight || {
        provision_fail "PREFLIGHT_FAILED" "Wymagania wstępne dla phpMyAdmin nie zostały spełnione."
        return 1
      }
      provision_report_progress 25 "Instalacja phpMyAdmin, PHP-FPM i konfiguracji vhost Nginx"
      if ! provision_run_with_progress "phpmyadmin-install" phpmyadmin_install_impl; then
        phpmyadmin_install_abort 2>/dev/null || true
        provision_operation_fail "INSTALL_FAILED" "Instalacja phpMyAdmin nie powiodła się."
        return 1
      fi
      local pma_php_ver
      pma_php_ver=$(phpmyadmin_detect_php_version 2>/dev/null || printf 'nieznana')
      write_state phpmyadmin \
        "version=${PHPMYADMIN_VERSION}" \
        "fqdn=${PMA_FQDN}" \
        "https=${PMA_LETSENCRYPT}" \
        "php_version=${pma_php_ver}" \
        "database_user=$([[ "$PMA_CREATE_DB_ADMIN" == true ]] && printf '%s' "$PMA_DB_USER")"
      ;;

    *)
      provision_fail "UNSUPPORTED_APP" "Nieobsługiwany typ aplikacji: $app"
      return 1
      ;;
  esac

  provision_report_progress 100 "Instalacja zakończona pomyślnie"
  provision_complete
  ui_success "Aplikacja $app została pomyślnie zainstalowana i skonfigurowana!"
  return 0
}
