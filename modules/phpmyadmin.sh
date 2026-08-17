#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

PHPMYADMIN_VERSION="5.2.3"
PHPMYADMIN_SHA256="12ba1c425fa4071abbd4e7668c9ebdeac0b0755a467a6d6d5026122bb47c102b"
PHPMYADMIN_ARCHIVE="phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.gz"
PHPMYADMIN_URL="https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/${PHPMYADMIN_ARCHIVE}"
PHPMYADMIN_ROOT="${PHPMYADMIN_ROOT:-/var/www/phpmyadmin}"
PHPMYADMIN_DATA_DIR="${PHPMYADMIN_DATA_DIR:-/var/lib/phpmyadmin}"
PHPMYADMIN_NGINX_AVAILABLE="${PHPMYADMIN_NGINX_AVAILABLE:-/etc/nginx/sites-available/blackhost-phpmyadmin.conf}"
PHPMYADMIN_NGINX_ENABLED="${PHPMYADMIN_NGINX_ENABLED:-/etc/nginx/sites-enabled/blackhost-phpmyadmin.conf}"
PHPMYADMIN_NGINX_RATE="${PHPMYADMIN_NGINX_RATE:-/etc/nginx/conf.d/blackhost-phpmyadmin-rate.conf}"

phpmyadmin_installed() {
  [[ -f "${PHPMYADMIN_ROOT}/index.php" \
    && -f "${PHPMYADMIN_ROOT}/libraries/classes/Version.php" \
    && -f "${PHPMYADMIN_ROOT}/config.inc.php" ]]
}

phpmyadmin_files_present() {
  [[ -e "$PHPMYADMIN_ROOT" || -L "$PHPMYADMIN_ROOT" \
    || -e "$PHPMYADMIN_DATA_DIR" || -L "$PHPMYADMIN_DATA_DIR" \
    || -e "$PHPMYADMIN_NGINX_AVAILABLE" || -L "$PHPMYADMIN_NGINX_AVAILABLE" \
    || -e "$PHPMYADMIN_NGINX_ENABLED" || -L "$PHPMYADMIN_NGINX_ENABLED" \
    || -e "$PHPMYADMIN_NGINX_RATE" || -L "$PHPMYADMIN_NGINX_RATE" ]]
}

phpmyadmin_version() {
  local root=${1:-$PHPMYADMIN_ROOT}
  sed -nE "s/.*VERSION = '([^']+)'.*/\1/p" \
    "${root}/libraries/classes/Version.php" 2>/dev/null | head -n 1
}

phpmyadmin_state_value() {
  local key=$1 state_file="${BLACKHOST_STATE_DIR}/phpmyadmin.state" value=""
  if [[ -r "$state_file" ]]; then
    value=$(sed -n "s/^${key}=//p" "$state_file" | head -n 1)
    value=${value#\'}
    value=${value%\'}
  fi
  printf '%s' "$value"
}

phpmyadmin_fqdn() {
  local fqdn
  fqdn=$(phpmyadmin_state_value fqdn)
  if [[ -z "$fqdn" && -r "$PHPMYADMIN_NGINX_AVAILABLE" ]]; then
    fqdn=$(sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^;[:space:]]+).*/\1/p' \
      "$PHPMYADMIN_NGINX_AVAILABLE" | head -n 1)
  fi
  printf '%s' "$fqdn"
}

phpmyadmin_status() {
  local state="off" details="" version="" fqdn="" scheme="http" socket=""
  if phpmyadmin_installed; then
    state="warn"
    version=$(phpmyadmin_version)
    fqdn=$(phpmyadmin_fqdn)
    [[ -n "$fqdn" && -f "/etc/letsencrypt/live/${fqdn}/fullchain.pem" ]] && scheme="https"
    details="${version:+v${version} · }${fqdn:+${scheme}://${fqdn} · }wymaga kontroli"
    socket=$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+).*/\1/p' \
      "$PHPMYADMIN_NGINX_AVAILABLE" 2>/dev/null | head -n 1)
    if nginx_installed \
      && systemctl is-active --quiet nginx 2>/dev/null \
      && nginx -t >/dev/null 2>&1 \
      && [[ -r "$PHPMYADMIN_NGINX_AVAILABLE" && -S "$socket" ]]; then
      state="ok"
      details="${version:+v${version}}${fqdn:+ · ${scheme}://${fqdn}}"
    fi
  elif phpmyadmin_files_present; then
    state="warn"
    details="wykryto niepełną instalację"
  fi
  ui_status_row "phpMyAdmin" "$state" "$details"
}

phpmyadmin_preflight() {
  local os_id
  require_linux || return 1
  require_root || return 1
  [[ -r /etc/os-release ]] || {
    ui_error "Nie udało się rozpoznać systemu operacyjnego."
    return 1
  }
  os_id=$(. /etc/os-release; printf '%s' "$ID")
  case "$os_id" in
    debian|ubuntu) ;;
    *)
      ui_error "Instalator phpMyAdmin obsługuje obecnie Debian i Ubuntu."
      return 1
      ;;
  esac
  [[ "$PHPMYADMIN_ROOT" == /var/www/* \
    && "$PHPMYADMIN_DATA_DIR" == /var/lib/* \
    && "$PHPMYADMIN_NGINX_AVAILABLE" == /etc/nginx/* \
    && "$PHPMYADMIN_NGINX_ENABLED" == /etc/nginx/* \
    && "$PHPMYADMIN_NGINX_RATE" == /etc/nginx/* ]] || {
    ui_error "Nieprawidłowa ścieżka instalacji phpMyAdmin."
    return 1
  }
  [[ "$(basename "$PHPMYADMIN_ROOT")" == phpmyadmin \
    && "$(basename "$PHPMYADMIN_DATA_DIR")" == phpmyadmin \
    && "$(basename "$PHPMYADMIN_NGINX_AVAILABLE")" == blackhost-phpmyadmin.conf \
    && "$(basename "$PHPMYADMIN_NGINX_ENABLED")" == blackhost-phpmyadmin.conf \
    && "$(basename "$PHPMYADMIN_NGINX_RATE")" == blackhost-phpmyadmin-rate.conf ]] || {
    ui_error "Ścieżki zarządzane przez phpMyAdmin mają nieoczekiwane nazwy."
    return 1
  }
  require_commands apt-get systemctl flock install awk sed grep find sort tar sha256sum mktemp mv ln rm mkdir chown chmod cp || return 1
  ensure_runtime_dirs || return 1
  acquire_operation_lock || return 1
}

phpmyadmin_detect_php_version() {
  command -v php >/dev/null 2>&1 || return 1
  php -r 'printf("%d.%d", PHP_MAJOR_VERSION, PHP_MINOR_VERSION);' 2>/dev/null
}

phpmyadmin_detect_fpm_socket() {
  local php_version=${1:-} socket
  if [[ -n "$php_version" && -S "/run/php/php${php_version}-fpm.sock" ]]; then
    printf '%s' "/run/php/php${php_version}-fpm.sock"
    return 0
  fi
  while IFS= read -r socket; do
    [[ -S "$socket" ]] || continue
    printf '%s' "$socket"
    return 0
  done < <(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -Vr)
  return 1
}

phpmyadmin_install_dependencies() {
  local php_version php_id fpm_service database_service
  local -a packages=(nginx curl ca-certificates tar)

  php_version=$(phpmyadmin_detect_php_version 2>/dev/null || true)
  if [[ -n "$php_version" ]]; then
    packages+=(
      "php${php_version}-fpm"
      "php${php_version}-mysql"
      "php${php_version}-mbstring"
      "php${php_version}-zip"
      "php${php_version}-gd"
      "php${php_version}-curl"
      "php${php_version}-xml"
    )
  else
    packages+=(php-cli php-fpm php-mysql php-mbstring php-zip php-gd php-curl php-xml)
  fi
  if [[ "$PMA_LETSENCRYPT" == true ]]; then
    packages+=(certbot python3-certbot-nginx)
  fi
  if ! systemctl list-unit-files mariadb.service mysql.service 2>/dev/null \
    | grep -qE '^(mariadb|mysql)\.service'; then
    packages+=(mariadb-server)
  fi

  printf 'BlackHost stage: phpmyadmin repositories\n'
  DEBIAN_FRONTEND=noninteractive apt-get update || return 1
  printf 'BlackHost stage: phpmyadmin packages\n'
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || return 1
  hash -r

  php_version=$(phpmyadmin_detect_php_version) || return 1
  php_id=$(php -r 'printf("%d", PHP_VERSION_ID);' 2>/dev/null || true)
  [[ "$php_id" =~ ^[0-9]+$ && "$php_id" -ge 70205 ]] || {
    printf 'phpMyAdmin %s wymaga PHP 7.2.5 lub nowszego.\n' "$PHPMYADMIN_VERSION" >&2
    return 1
  }

  fpm_service="php${php_version}-fpm"
  systemctl enable --now "$fpm_service" || return 1
  systemctl enable --now nginx || return 1
  if systemctl list-unit-files mariadb.service 2>/dev/null | grep -q '^mariadb.service'; then
    database_service=mariadb
  elif systemctl list-unit-files mysql.service 2>/dev/null | grep -q '^mysql.service'; then
    database_service=mysql
  else
    printf 'Nie znaleziono usługi MariaDB/MySQL.\n' >&2
    return 1
  fi
  systemctl enable --now "$database_service" || return 1
  if command -v mariadb >/dev/null 2>&1; then
    PMA_DB_CLIENT=mariadb
  elif command -v mysql >/dev/null 2>&1; then
    PMA_DB_CLIENT=mysql
  else
    printf 'Nie znaleziono klienta MariaDB/MySQL.\n' >&2
    return 1
  fi
  PMA_PHP_VERSION=$php_version
  PMA_PHP_FPM_SERVICE=$fpm_service
  PMA_PHP_SOCKET=$(phpmyadmin_detect_fpm_socket "$php_version") || {
    printf 'Nie znaleziono aktywnego gniazda PHP-FPM.\n' >&2
    return 1
  }
}

phpmyadmin_remove_temp_dir() {
  local target=${1:-}
  case "$target" in
    /tmp/blackhost-phpmyadmin.*) [[ -d "$target" ]] && rm -rf -- "$target" ;;
    *) return 1 ;;
  esac
}

phpmyadmin_remove_managed_tree() {
  local target=${1:-} parent base
  parent=$(dirname "$PHPMYADMIN_ROOT")
  base=$(basename "$PHPMYADMIN_ROOT")
  case "$target" in
    "$PHPMYADMIN_ROOT"|"$parent/.${base}.rollback-"*|"$parent/.${base}.update-"*)
      [[ -e "$target" || -L "$target" ]] && rm -rf -- "$target"
      ;;
    *) return 1 ;;
  esac
}

phpmyadmin_remove_data_dir() {
  local target=${1:-}
  [[ "$target" == "$PHPMYADMIN_DATA_DIR" && "$target" != "/" \
    && ( -d "$target" || -L "$target" ) ]] || return 1
  rm -rf -- "$target"
}

phpmyadmin_prepare_release() {
  local actual_hash entry expected_prefix
  PMA_TEMP_DIR=$(mktemp -d /tmp/blackhost-phpmyadmin.XXXXXX) || return 1
  PMA_ARCHIVE_PATH="${PMA_TEMP_DIR}/${PHPMYADMIN_ARCHIVE}"
  PMA_STAGING_DIR="${PMA_TEMP_DIR}/phpmyadmin"
  expected_prefix="phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages"

  printf 'BlackHost stage: phpmyadmin download\n'
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --output "$PMA_ARCHIVE_PATH" "$PHPMYADMIN_URL" || return 1

  printf 'BlackHost stage: phpmyadmin checksum\n'
  actual_hash=$(sha256sum "$PMA_ARCHIVE_PATH" | awk '{print tolower($1)}') || return 1
  [[ "$actual_hash" == "$PHPMYADMIN_SHA256" ]] || {
    printf 'Suma SHA-256 phpMyAdmin jest inna niż oczekiwana.\n' >&2
    return 1
  }

  tar -tzf "$PMA_ARCHIVE_PATH" >"${PMA_TEMP_DIR}/archive.list" || return 1
  while IFS= read -r entry; do
    [[ "$entry" == "$expected_prefix" || "$entry" == "$expected_prefix/"* ]] || return 1
    [[ "$entry" != /* && "/$entry/" != *"/../"* ]] || return 1
  done <"${PMA_TEMP_DIR}/archive.list"
  tar -tvzf "$PMA_ARCHIVE_PATH" \
    | awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") bad = 1 } END { exit bad }' \
    || return 1

  printf 'BlackHost stage: phpmyadmin extract\n'
  mkdir -p "$PMA_STAGING_DIR"
  tar -xzf "$PMA_ARCHIVE_PATH" -C "$PMA_STAGING_DIR" --strip-components=1 || return 1
  [[ -f "${PMA_STAGING_DIR}/index.php" \
    && -f "${PMA_STAGING_DIR}/libraries/classes/Version.php" \
    && "$(phpmyadmin_version "$PMA_STAGING_DIR")" == "$PHPMYADMIN_VERSION" ]] || return 1
}

phpmyadmin_render_config() {
  local fqdn=$1 secret=$2 force_ssl=$3 scheme="http" force_value="false"
  [[ "$force_ssl" == true ]] && scheme="https" && force_value="true"
  cat <<EOF
<?php
declare(strict_types=1);

\$cfg['blowfish_secret'] = '${secret}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['AllowArbitraryServer'] = false;
\$cfg['PmaAbsoluteUri'] = '${scheme}://${fqdn}/';
\$cfg['ForceSSL'] = ${force_value};
\$cfg['TempDir'] = '${PHPMYADMIN_DATA_DIR}/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['LoginCookieValidity'] = 1800;
EOF
}

phpmyadmin_render_nginx_rate() {
  cat <<'EOF'
limit_req_zone $binary_remote_addr zone=blackhost_phpmyadmin_login:10m rate=30r/m;
EOF
}

phpmyadmin_render_nginx_site() {
  local fqdn=$1 socket=$2
  cat <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${fqdn};

  root ${PHPMYADMIN_ROOT};
  index index.php;
  client_max_body_size 64m;

  access_log /var/log/nginx/phpmyadmin-access.log;
  error_log /var/log/nginx/phpmyadmin-error.log;

  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header Referrer-Policy "same-origin" always;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ ^/(setup|libraries|templates|vendor)/ {
    deny all;
  }

  location ~ /\. {
    deny all;
  }

  location ~ \.php$ {
    limit_req zone=blackhost_phpmyadmin_login burst=60 nodelay;
    try_files \$uri =404;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY "";
    fastcgi_param HTTPS \$https if_not_empty;
    fastcgi_pass unix:${socket};
    fastcgi_read_timeout 300;
  }
}
EOF
}

phpmyadmin_domain_available() {
  local fqdn=$1 config
  for config in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [[ -f "$config" || -L "$config" ]] || continue
    [[ "$config" == "$PHPMYADMIN_NGINX_ENABLED" || "$config" == "$PHPMYADMIN_NGINX_RATE" ]] && continue
    if grep -Fq -- "$fqdn" "$config" 2>/dev/null; then
      return 1
    fi
  done
}

phpmyadmin_install_abort() {
  if [[ "${PMA_DB_USER_CREATED:-false}" == true && -n "${PMA_DB_CLIENT:-}" \
    && -n "${PMA_DB_USER:-}" ]]; then
    "$PMA_DB_CLIENT" --protocol=socket -u root \
      -e "DROP USER IF EXISTS '${PMA_DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;" \
      >/dev/null 2>&1 || true
  fi
  rm -f -- "$PHPMYADMIN_NGINX_ENABLED" "$PHPMYADMIN_NGINX_AVAILABLE" "$PHPMYADMIN_NGINX_RATE"
  if nginx_installed && nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || true
  fi
  phpmyadmin_remove_managed_tree "$PHPMYADMIN_ROOT" 2>/dev/null || true
  phpmyadmin_remove_data_dir "$PHPMYADMIN_DATA_DIR" 2>/dev/null || true
  [[ -n "${PMA_TEMP_DIR:-}" ]] && phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR" 2>/dev/null || true
}

phpmyadmin_install_steps() {
  local secret config_file rate_file
  PMA_DB_USER_CREATED=false
  phpmyadmin_install_dependencies || return 1
  phpmyadmin_prepare_release || return 1

  if [[ "$PMA_CREATE_DB_ADMIN" == true ]]; then
    printf 'BlackHost stage: phpmyadmin database\n'
    if "$PMA_DB_CLIENT" --protocol=socket -N -B -u root \
      -e "SELECT 1 FROM mysql.user WHERE User='${PMA_DB_USER}' AND Host='127.0.0.1' LIMIT 1;" \
      | grep -q '^1$'; then
      if [[ "${PMA_RESET_EXISTING_DB_USER:-false}" != true ]]; then
        printf 'Użytkownik bazy %s@127.0.0.1 już istnieje; jego hasło nie zostało zmienione.\n' \
          "$PMA_DB_USER" >&2
        return 1
      fi
      "$PMA_DB_CLIENT" --protocol=socket -u root -e \
        "ALTER USER '${PMA_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PMA_DB_PASSWORD}'; GRANT ALL PRIVILEGES ON *.* TO '${PMA_DB_USER}'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" || return 1
    else
      "$PMA_DB_CLIENT" --protocol=socket -u root -e \
        "CREATE USER '${PMA_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PMA_DB_PASSWORD}';" || return 1
      PMA_DB_USER_CREATED=true
      "$PMA_DB_CLIENT" --protocol=socket -u root -e \
        "GRANT ALL PRIVILEGES ON *.* TO '${PMA_DB_USER}'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" \
        || return 1
    fi
  fi

  printf 'BlackHost stage: phpmyadmin configure\n'
  secret=$(random_secret) || return 1
  rm -rf -- "${PMA_STAGING_DIR}/setup"
  phpmyadmin_render_config "$PMA_FQDN" "$secret" "$PMA_LETSENCRYPT" \
    >"${PMA_STAGING_DIR}/config.inc.php"

  install -d -m 755 "$(dirname "$PHPMYADMIN_ROOT")" || return 1
  mv -- "$PMA_STAGING_DIR" "$PHPMYADMIN_ROOT" || return 1
  chown -R root:www-data "$PHPMYADMIN_ROOT" || return 1
  find "$PHPMYADMIN_ROOT" -type d -exec chmod 755 {} + || return 1
  find "$PHPMYADMIN_ROOT" -type f -exec chmod 644 {} + || return 1
  chmod 640 "${PHPMYADMIN_ROOT}/config.inc.php" || return 1
  install -d -o www-data -g www-data -m 700 "${PHPMYADMIN_DATA_DIR}/tmp" || return 1

  config_file="${PMA_TEMP_DIR}/nginx.conf"
  rate_file="${PMA_TEMP_DIR}/rate.conf"
  phpmyadmin_render_nginx_site "$PMA_FQDN" "$PMA_PHP_SOCKET" >"$config_file"
  phpmyadmin_render_nginx_rate >"$rate_file"
  install -d -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d || return 1
  install -m 644 "$config_file" "$PHPMYADMIN_NGINX_AVAILABLE" || return 1
  install -m 644 "$rate_file" "$PHPMYADMIN_NGINX_RATE" || return 1
  ln -sfn "$PHPMYADMIN_NGINX_AVAILABLE" "$PHPMYADMIN_NGINX_ENABLED" || return 1
  nginx -t || return 1
  systemctl reload nginx || return 1

  if [[ "$PMA_LETSENCRYPT" == true ]]; then
    printf 'BlackHost stage: phpmyadmin certificate\n'
    certbot --nginx --redirect --non-interactive --agree-tos --no-eff-email \
      --email "$PMA_EMAIL" -d "$PMA_FQDN" || return 1
    nginx -t || return 1
    systemctl reload nginx || return 1
  fi

  printf 'BlackHost stage: phpmyadmin verify\n'
  [[ "$(phpmyadmin_version)" == "$PHPMYADMIN_VERSION" ]] || return 1
  php -l "${PHPMYADMIN_ROOT}/config.inc.php" >/dev/null || return 1
}

phpmyadmin_install_impl() {
  trap 'phpmyadmin_install_abort; exit 130' INT TERM HUP
  if ! phpmyadmin_install_steps; then
    phpmyadmin_install_abort
    trap - INT TERM HUP
    return 1
  fi
  phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR"
  PMA_TEMP_DIR=""
  trap - INT TERM HUP
  printf 'BlackHost stage: phpmyadmin complete\n'
}

phpmyadmin_prompt_install() {
  ui_header "INSTALACJA PHPMYADMIN"
  ui_section "KONFIGURACJA"
  ui_info "phpMyAdmin otrzyma osobną domenę i konfigurację Nginx."

  while :; do
    ui_prompt PMA_FQDN "Domena phpMyAdmin" "db.example.com"
    valid_fqdn "$PMA_FQDN" && break
    ui_error "Podaj pełną domenę, np. db.example.com."
  done

  PMA_LETSENCRYPT=false
  ui_confirm "Pobrać certyfikat HTTPS z Let's Encrypt?" y && PMA_LETSENCRYPT=true || true
  PMA_EMAIL=""
  if [[ "$PMA_LETSENCRYPT" == true ]]; then
    ui_warn "Domena musi wskazywać na ten serwer, a porty TCP 80 i 443 muszą być otwarte."
    ui_confirm "Akceptujesz warunki usługi Let's Encrypt?" y || PMA_LETSENCRYPT=false
  fi
  if [[ "$PMA_LETSENCRYPT" == true ]]; then
    while :; do
      ui_prompt PMA_EMAIL "E-mail Let's Encrypt" "admin@${PMA_FQDN#*.}"
      valid_email "$PMA_EMAIL" && break
      ui_error "Nieprawidłowy adres e-mail."
    done
    if command -v getent >/dev/null 2>&1 && ! getent ahosts "$PMA_FQDN" >/dev/null 2>&1; then
      ui_warn "Domena $PMA_FQDN nie jest obecnie rozwiązywana przez DNS."
      ui_confirm "Kontynuować mimo braku rekordu DNS?" n || return 1
    fi
  fi

  if ! phpmyadmin_domain_available "$PMA_FQDN"; then
    ui_error "Domena $PMA_FQDN występuje już w aktywnej konfiguracji Nginx."
    return 1
  fi

  PMA_CREATE_DB_ADMIN=false
  PMA_DB_USER=""
  PMA_DB_PASSWORD=""
  if [[ "$PMA_LETSENCRYPT" != true ]]; then
    ui_warn "Bez HTTPS BlackHost nie utworzy uprzywilejowanego konta bazy."
  elif ui_confirm "Utworzyć administratora MariaDB do logowania w phpMyAdmin?" y; then
    PMA_CREATE_DB_ADMIN=true
    while :; do
      ui_prompt PMA_DB_USER "Login administratora MariaDB" "dbadmin"
      valid_db_identifier "$PMA_DB_USER" && break
      ui_error "Dozwolone są litery, cyfry i znak _."
    done
    PMA_DB_PASSWORD=$(random_secret)
  fi

  ui_section "PODSUMOWANIE INSTALACJI"
  ui_summary_group "PHPMYADMIN"
  ui_summary_row "Wersja" "v${PHPMYADMIN_VERSION}"
  ui_summary_row "Domena" "$PMA_FQDN"
  ui_summary_row "HTTPS" "$(ui_state_value "$PMA_LETSENCRYPT" "Let's Encrypt" "Wyłączony")"
  ui_summary_group "DOSTĘP"
  ui_summary_row "Baza" "MariaDB/MySQL na 127.0.0.1"
  ui_summary_row "Logowanie" "Cookie · dane użytkownika bazy"
  ui_summary_row "Dowolny host DB" "Wyłączony"
  if [[ "$PMA_CREATE_DB_ADMIN" == true ]]; then
    ui_summary_row "Administrator DB" "$PMA_DB_USER"
    ui_summary_row "Hasło DB" "$PMA_DB_PASSWORD (wygenerowane)"
    ui_warn "Zapisz wygenerowane hasło administratora bazy przed instalacją."
  else
    ui_summary_row "Administrator DB" "Nie będzie tworzony"
    ui_info "Do logowania użyjesz istniejącego konta MariaDB/MySQL."
  fi
  ui_warn "Publiczny phpMyAdmin powinien być regularnie aktualizowany."
  ui_confirm "Rozpocząć instalację phpMyAdmin?" y
}

phpmyadmin_install() {
  local installed_php_version
  phpmyadmin_preflight || return 0
  if phpmyadmin_installed; then
    ui_warn "phpMyAdmin jest już zainstalowany."
    return 0
  fi
  if phpmyadmin_files_present; then
    ui_error "Wykryto pozostałości poprzedniej instalacji phpMyAdmin. Usuń je przez menu modułu."
    return 0
  fi
  phpmyadmin_prompt_install || return 0

  if ! run_with_progress "phpmyadmin-install" phpmyadmin_install_impl; then
    phpmyadmin_install_abort
    ui_error "Instalacja phpMyAdmin nie została dokończona."
    return 0
  fi

  installed_php_version=$(phpmyadmin_detect_php_version 2>/dev/null || printf 'nieznana')
  write_state phpmyadmin \
    "version=${PHPMYADMIN_VERSION}" \
    "fqdn=${PMA_FQDN}" \
    "https=${PMA_LETSENCRYPT}" \
    "php_version=${installed_php_version}" \
    "database_user=$([[ "$PMA_CREATE_DB_ADMIN" == true ]] && printf '%s' "$PMA_DB_USER")"
  ui_success "phpMyAdmin został zainstalowany: $([[ "$PMA_LETSENCRYPT" == true ]] && printf 'https' || printf 'http')://${PMA_FQDN}"
}

phpmyadmin_prepare_update_tree() {
  local new_root=$1 current_config="${PHPMYADMIN_ROOT}/config.inc.php"
  phpmyadmin_prepare_release || return 1
  printf 'BlackHost stage: phpmyadmin update prepare\n'
  rm -rf -- "${PMA_STAGING_DIR}/setup"
  install -m 640 "$current_config" "${PMA_STAGING_DIR}/config.inc.php" || return 1
  mv -- "$PMA_STAGING_DIR" "$new_root" || return 1
  chown -R root:www-data "$new_root" || return 1
  find "$new_root" -type d -exec chmod 755 {} + || return 1
  find "$new_root" -type f -exec chmod 644 {} + || return 1
  chmod 640 "${new_root}/config.inc.php" || return 1
}

phpmyadmin_update_impl() {
  local backup_root new_root parent base
  parent=$(dirname "$PHPMYADMIN_ROOT")
  base=$(basename "$PHPMYADMIN_ROOT")
  backup_root="${parent}/.${base}.rollback-$(date +%Y%m%d%H%M%S)-$$"
  new_root="${parent}/.${base}.update-${PHPMYADMIN_VERSION}-$$"
  trap '[[ -e "$new_root" ]] && phpmyadmin_remove_managed_tree "$new_root" 2>/dev/null || true; [[ -n "${PMA_TEMP_DIR:-}" ]] && phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR" 2>/dev/null || true; exit 130' INT TERM HUP
  if ! phpmyadmin_prepare_update_tree "$new_root"; then
    phpmyadmin_remove_managed_tree "$new_root" 2>/dev/null || true
    [[ -n "${PMA_TEMP_DIR:-}" ]] && phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR" 2>/dev/null || true
    trap - INT TERM HUP
    return 1
  fi

  printf 'BlackHost stage: phpmyadmin update swap\n'
  trap '' INT TERM HUP
  if ! mv -- "$PHPMYADMIN_ROOT" "$backup_root"; then
    trap - INT TERM HUP
    phpmyadmin_remove_managed_tree "$new_root" 2>/dev/null || true
    phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR" 2>/dev/null || true
    return 1
  fi
  if ! mv -- "$new_root" "$PHPMYADMIN_ROOT" \
    || [[ "$(phpmyadmin_version)" != "$PHPMYADMIN_VERSION" ]] \
    || ! php -l "${PHPMYADMIN_ROOT}/config.inc.php" >/dev/null; then
    [[ -e "$PHPMYADMIN_ROOT" ]] && mv -- "$PHPMYADMIN_ROOT" "$new_root" || true
    mv -- "$backup_root" "$PHPMYADMIN_ROOT" || true
    trap - INT TERM HUP
    phpmyadmin_remove_managed_tree "$new_root" 2>/dev/null || true
    phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR" 2>/dev/null || true
    printf 'Aktualizacja phpMyAdmin nie przeszła kontroli. Przywrócono poprzednią wersję.\n' >&2
    return 1
  fi
  trap - INT TERM HUP
  phpmyadmin_remove_managed_tree "$backup_root"
  phpmyadmin_remove_temp_dir "$PMA_TEMP_DIR"
  printf 'BlackHost stage: phpmyadmin update complete\n'
}

phpmyadmin_version_is_newer() {
  local candidate=$1 current=$2 newest
  [[ "$candidate" != "$current" ]] || return 1
  newest=$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | sed -n '$p')
  [[ "$newest" == "$candidate" ]]
}

phpmyadmin_update() {
  local current_version fqdn https database_user
  phpmyadmin_preflight || return 0
  phpmyadmin_installed || {
    ui_error "phpMyAdmin nie jest zainstalowany."
    return 0
  }
  require_commands curl php || return 0
  current_version=$(phpmyadmin_version)
  if [[ "$current_version" == "$PHPMYADMIN_VERSION" ]]; then
    ui_success "phpMyAdmin jest aktualny (v${current_version})."
    return 0
  fi
  if phpmyadmin_version_is_newer "$current_version" "$PHPMYADMIN_VERSION"; then
    ui_warn "Zainstalowana wersja v${current_version} jest nowsza niż obsługiwane v${PHPMYADMIN_VERSION}."
    return 0
  fi

  ui_header "AKTUALIZACJA PHPMYADMIN"
  ui_section "PODSUMOWANIE"
  ui_summary_row "Obecna wersja" "v${current_version:-nieznana}"
  ui_summary_row "Wersja docelowa" "v${PHPMYADMIN_VERSION}"
  ui_info "Konfiguracja domeny, SSL i logowania zostanie zachowana."
  ui_confirm "Zaktualizować phpMyAdmin?" y || return 0

  if ! run_with_progress "phpmyadmin-update" phpmyadmin_update_impl; then
    ui_error "Aktualizacja phpMyAdmin nie została dokończona."
    return 0
  fi
  fqdn=$(phpmyadmin_fqdn)
  https=$(phpmyadmin_state_value https)
  database_user=$(phpmyadmin_state_value database_user)
  write_state phpmyadmin \
    "version=${PHPMYADMIN_VERSION}" \
    "fqdn=${fqdn}" \
    "https=${https:-false}" \
    "database_user=${database_user}"
  ui_success "phpMyAdmin został zaktualizowany do v${PHPMYADMIN_VERSION}."
}

phpmyadmin_uninstall_impl() {
  local backup_dir
  backup_dir=$(mktemp -d /tmp/blackhost-phpmyadmin.XXXXXX) || return 1
  [[ -e "$PHPMYADMIN_NGINX_AVAILABLE" ]] && cp -a "$PHPMYADMIN_NGINX_AVAILABLE" "$backup_dir/available" || true
  [[ -e "$PHPMYADMIN_NGINX_ENABLED" || -L "$PHPMYADMIN_NGINX_ENABLED" ]] \
    && cp -a "$PHPMYADMIN_NGINX_ENABLED" "$backup_dir/enabled" || true
  [[ -e "$PHPMYADMIN_NGINX_RATE" ]] && cp -a "$PHPMYADMIN_NGINX_RATE" "$backup_dir/rate" || true

  printf 'BlackHost stage: phpmyadmin uninstall nginx\n'
  rm -f -- "$PHPMYADMIN_NGINX_ENABLED" "$PHPMYADMIN_NGINX_AVAILABLE" "$PHPMYADMIN_NGINX_RATE"
  if nginx_installed && ! nginx -t; then
    [[ -e "$backup_dir/available" ]] && cp -a "$backup_dir/available" "$PHPMYADMIN_NGINX_AVAILABLE"
    [[ -e "$backup_dir/enabled" || -L "$backup_dir/enabled" ]] && cp -a "$backup_dir/enabled" "$PHPMYADMIN_NGINX_ENABLED"
    [[ -e "$backup_dir/rate" ]] && cp -a "$backup_dir/rate" "$PHPMYADMIN_NGINX_RATE"
    phpmyadmin_remove_temp_dir "$backup_dir"
    return 1
  fi
  nginx_installed && systemctl reload nginx || true

  printf 'BlackHost stage: phpmyadmin uninstall files\n'
  phpmyadmin_remove_managed_tree "$PHPMYADMIN_ROOT" || true
  phpmyadmin_remove_data_dir "$PHPMYADMIN_DATA_DIR" 2>/dev/null || true

  if [[ "$PMA_REMOVE_CERT" == true && -n "$PMA_FQDN" ]] && command -v certbot >/dev/null 2>&1; then
    printf 'BlackHost stage: phpmyadmin uninstall certificate\n'
    certbot delete --non-interactive --cert-name "$PMA_FQDN" || true
  fi
  if [[ "$PMA_REMOVE_DB_USER" == true && -n "$PMA_DB_USER" ]]; then
    printf 'BlackHost stage: phpmyadmin uninstall database\n'
    if command -v mariadb >/dev/null 2>&1; then
      mariadb --protocol=socket -u root \
        -e "DROP USER IF EXISTS '${PMA_DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;" || true
    elif command -v mysql >/dev/null 2>&1; then
      mysql --protocol=socket -u root \
        -e "DROP USER IF EXISTS '${PMA_DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;" || true
    fi
  fi
  phpmyadmin_remove_temp_dir "$backup_dir"
  printf 'BlackHost stage: phpmyadmin uninstall complete\n'
}

phpmyadmin_uninstall() {
  local phrase
  phpmyadmin_preflight || return 0
  phpmyadmin_files_present || {
    ui_warn "Nie wykryto instalacji phpMyAdmin."
    return 0
  }
  PMA_FQDN=$(phpmyadmin_fqdn)
  PMA_DB_USER=$(phpmyadmin_state_value database_user)
  valid_db_identifier "$PMA_DB_USER" || PMA_DB_USER=""
  PMA_REMOVE_CERT=false
  PMA_REMOVE_DB_USER=false

  ui_header "ODINSTALOWANIE PHPMYADMIN"
  ui_section "ZAKRES OPERACJI"
  ui_warn "Pliki phpMyAdmin i jego konfiguracja Nginx zostaną usunięte."
  ui_info "MariaDB, bazy danych, PHP, Nginx i ich pozostałe konfiguracje zostaną zachowane."
  if [[ -n "$PMA_FQDN" && -d "/etc/letsencrypt/live/${PMA_FQDN}" ]]; then
    ui_confirm "Usunąć również certyfikat Let's Encrypt dla ${PMA_FQDN}?" n && PMA_REMOVE_CERT=true || true
  fi
  if [[ -n "$PMA_DB_USER" ]]; then
    ui_confirm "Usunąć konto bazy ${PMA_DB_USER}@127.0.0.1 utworzone przez BlackHost?" n \
      && PMA_REMOVE_DB_USER=true || true
  fi
  ui_prompt phrase "Aby kontynuować, wpisz: USUN PHPMYADMIN" ""
  [[ "$phrase" == "USUN PHPMYADMIN" ]] || {
    ui_info "Anulowano."
    return 0
  }

  if ! run_with_progress "phpmyadmin-uninstall" phpmyadmin_uninstall_impl; then
    ui_error "Odinstalowanie phpMyAdmin nie zostało dokończone."
    return 0
  fi
  rm -f -- "${BLACKHOST_STATE_DIR}/phpmyadmin.state"
  ui_success "phpMyAdmin został odinstalowany."
}

phpmyadmin_menu() {
  local choice version header
  while :; do
    version=$(phpmyadmin_version 2>/dev/null || true)
    header="PHPMYADMIN"
    [[ -n "$version" ]] && header+=" · v${version}"
    ui_header "$header"
    ui_section "STAN"
    phpmyadmin_status
    ui_section "AKCJE"
    ui_option 1 "Zainstaluj phpMyAdmin" "Domena, Nginx, PHP-FPM i opcjonalny SSL"
    ui_option 2 "Aktualizuj phpMyAdmin" "Zweryfikowane wydanie z rollbackiem"
    ui_option 3 "Odinstaluj phpMyAdmin" "Zachowuje MariaDB, PHP i Nginx"
    ui_option 0 "Wróć" "Lista programów"
    ui_menu_prompt choice

    case "$choice" in
      1) phpmyadmin_install; ui_pause ;;
      2) phpmyadmin_update; ui_pause ;;
      3) phpmyadmin_uninstall; ui_pause ;;
      0) return 0 ;;
      *) ui_error "Nieprawidłowa opcja."; sleep 1 ;;
    esac
  done
}
