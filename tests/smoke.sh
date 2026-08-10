#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export BLACKHOST_ROOT="$ROOT"
export NO_COLOR=1

version_output=$("$ROOT/bin/blackhost" version)
[[ "$version_output" == "blackhost 1.1.0" ]]

temp_dir=$(mktemp -d /tmp/blackhost-cli-test.XXXXXX)
cleanup() {
  case "$temp_dir" in
    /tmp/blackhost-cli-test.*) rm -rf -- "$temp_dir" ;;
  esac
}
trap cleanup EXIT
ln -s "$ROOT/bin/blackhost" "$temp_dir/blackhost"
symlink_version_output=$("$temp_dir/blackhost" version)
[[ "$symlink_version_output" == "blackhost 1.1.0" ]]

help_output=$("$ROOT/bin/blackhost" help)
[[ "$help_output" == *"Użycie: blackhost"* ]]
[[ "$help_output" == *"installer"* ]]
[[ "$help_output" == *"nginx"* ]]
[[ "$help_output" == *"phpmyadmin"* ]]
[[ "$help_output" == *"speedtest"* ]]
[[ "$help_output" == *"update"* ]]
[[ "$help_output" == *"update --check"* ]]
main_menu_output=$(printf '0\n' | BLACKHOST_NO_ALT_SCREEN=1 "$ROOT/bin/blackhost")
[[ "$main_menu_output" == *"Aktualizacja CLI"* ]]
grep -qF 'BLACKHOST_UPDATE_APPLIED:-false' "$ROOT/bin/blackhost"
grep -qF '"$SOURCE_ROOT"/modules/*.sh' "$ROOT/install.sh"
grep -qF 'GNU General Public License' "$ROOT/LICENSE"
grep -qF 'Copyright (C) 2026 BlackHost.pl' "$ROOT/lib/core.sh"
grep -qF 'GPL-3.0-only' "$ROOT/README.md"
grep -qF '"$SOURCE_ROOT/LICENSE"' "$ROOT/install.sh"
grep -qF '"$SOURCE_ROOT/THIRD_PARTY.md"' "$ROOT/install.sh"

installer_output=$(printf '1\n0\n0\n' | BLACKHOST_NO_ALT_SCREEN=1 "$ROOT/bin/blackhost" installer)
[[ "$installer_output" == *"PROGRAMY"* ]]
[[ "$installer_output" == *"phpMyAdmin"* ]]
[[ "$installer_output" == *"PTERODACTYL"* ]]
[[ "$installer_output" != *"PTERODACTYL · v1.3.0"* ]]
[[ "$installer_output" == *"Zainstaluj Panel"* ]]
[[ "$installer_output" == *"Zainstaluj Blueprint"* ]]
[[ "$installer_output" == *"[ 4]  Zainstaluj Blueprint"* ]]
[[ "$installer_output" == *"[ 5]  Aktualizuj Panel"* ]]
[[ "$installer_output" == *"[ 6]  Aktualizuj Wings"* ]]
[[ "$installer_output" == *"[ 7]  Dokończ / napraw Panel"* ]]
[[ "$installer_output" == *"[ 8]  Odinstaluj Blueprint"* ]]
[[ "$installer_output" == *"[ 9]  Odinstaluj Panel"* ]]
[[ "$installer_output" == *"[10]  Odinstaluj Wings"* ]]

nginx_menu_output=$(printf '2\n0\n0\n' | BLACKHOST_NO_ALT_SCREEN=1 "$ROOT/bin/blackhost" installer)
[[ "$nginx_menu_output" == *"NGINX"* ]]
[[ "$nginx_menu_output" != *"INSTALATOR / NGINX"* ]]
[[ "$nginx_menu_output" == *"Zainstaluj Nginx"* ]]
[[ "$nginx_menu_output" == *"Odinstaluj Nginx"* ]]

phpmyadmin_menu_output=$(printf '3\n0\n0\n' | BLACKHOST_NO_ALT_SCREEN=1 "$ROOT/bin/blackhost" installer)
[[ "$phpmyadmin_menu_output" == *"PHPMYADMIN"* ]]
[[ "$phpmyadmin_menu_output" == *"Zainstaluj phpMyAdmin"* ]]
[[ "$phpmyadmin_menu_output" == *"Aktualizuj phpMyAdmin"* ]]
[[ "$phpmyadmin_menu_output" == *"Odinstaluj phpMyAdmin"* ]]

source "$ROOT/lib/ui.sh"
source "$ROOT/lib/core.sh"
source "$ROOT/modules/speedtest.sh"
source "$ROOT/modules/self_update.sh"
source "$ROOT/modules/pterodactyl.sh"
source "$ROOT/modules/blueprint.sh"
source "$ROOT/modules/nginx.sh"
source "$ROOT/modules/phpmyadmin.sh"
source "$ROOT/modules/installer.sh"

[[ "$PHPMYADMIN_VERSION" == '5.2.3' ]]
[[ "$PHPMYADMIN_SHA256" == '12ba1c425fa4071abbd4e7668c9ebdeac0b0755a467a6d6d5026122bb47c102b' ]]
phpmyadmin_version_is_newer '5.2.4' '5.2.3'
! phpmyadmin_version_is_newer '5.2.3' '5.2.3'
! phpmyadmin_version_is_newer '5.2.2' '5.2.3'

original_phpmyadmin_root=$PHPMYADMIN_ROOT
PHPMYADMIN_ROOT="$temp_dir/phpmyadmin-fixture"
mkdir -p "$PHPMYADMIN_ROOT/libraries/classes"
touch "$PHPMYADMIN_ROOT/index.php" "$PHPMYADMIN_ROOT/config.inc.php"
printf "%s\n" "public const VERSION = '5.2.3' . VERSION_SUFFIX;" \
  >"$PHPMYADMIN_ROOT/libraries/classes/Version.php"
phpmyadmin_installed
[[ "$(phpmyadmin_version)" == '5.2.3' ]]
PHPMYADMIN_ROOT=$original_phpmyadmin_root

phpmyadmin_config=$(phpmyadmin_render_config 'db.example.com' \
  '0123456789abcdef0123456789abcdef0123456789abcdef' true)
[[ "$phpmyadmin_config" == *"auth_type'] = 'cookie'"* ]]
[[ "$phpmyadmin_config" == *"host'] = '127.0.0.1'"* ]]
[[ "$phpmyadmin_config" == *"AllowArbitraryServer'] = false"* ]]
[[ "$phpmyadmin_config" == *"PmaAbsoluteUri'] = 'https://db.example.com/'"* ]]
[[ "$phpmyadmin_config" == *"ForceSSL'] = true"* ]]

phpmyadmin_nginx=$(phpmyadmin_render_nginx_site 'db.example.com' '/run/php/php8.3-fpm.sock')
[[ "$phpmyadmin_nginx" == *'server_name db.example.com;'* ]]
[[ "$phpmyadmin_nginx" == *'fastcgi_pass unix:/run/php/php8.3-fpm.sock;'* ]]
[[ "$phpmyadmin_nginx" == *'location ~ ^/(setup|libraries|templates|vendor)/'* ]]
[[ "$phpmyadmin_nginx" == *'limit_req zone=blackhost_phpmyadmin_login'* ]]
[[ "$(phpmyadmin_render_nginx_rate)" == *'rate=30r/m'* ]]
grep -qF 'USUN PHPMYADMIN' "$ROOT/modules/phpmyadmin.sh"
grep -qF 'certbot --nginx --redirect --non-interactive' "$ROOT/modules/phpmyadmin.sh"
grep -qF "GRANT ALL PRIVILEGES ON *.* TO" "$ROOT/modules/phpmyadmin.sh"
! sed -n '/write_state phpmyadmin/,/ui_success/p' "$ROOT/modules/phpmyadmin.sh" \
  | grep -qF 'PMA_DB_PASSWORD'

[[ "$(blackhost_release_version_from_tag v1.2.3)" == "1.2.3" ]]
[[ "$(blackhost_release_version_from_tag v10.20.30)" == "10.20.30" ]]
! blackhost_release_version_from_tag '1.2.3'
! blackhost_release_version_from_tag 'v1.2'
! blackhost_release_version_from_tag 'v1.2.3-beta.1'
! blackhost_release_version_from_tag 'v01.2.3'
! blackhost_release_version_from_tag 'v1234567890.2.3'
blackhost_version_is_newer '1.1.0' '1.0.9'
blackhost_version_is_newer '2.0.0' '1.99.99'
! blackhost_version_is_newer '1.0.0' '1.0.0'
! blackhost_version_is_newer '1.0.9' '1.1.0'
release_json='{"id":123,"tag_name":"v1.2.3","draft":false}'
[[ "$(printf '%s' "$release_json" | blackhost_release_tag_from_json)" == "v1.2.3" ]]

checksum_fixture="$temp_dir/release.sha256"
printf '%s  %s\n' \
  'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789' \
  'blackhost-v1.2.3.tar.gz' >"$checksum_fixture"
[[ "$(blackhost_update_checksum_from_file "$checksum_fixture" 'blackhost-v1.2.3.tar.gz')" \
  == 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' ]]
! blackhost_update_checksum_from_file "$checksum_fixture" 'inny-plik.tar.gz'

curl() {
  printf '%s\n' '{"id":123,"tag_name":"v1.2.3","draft":false}'
}
export -f curl
update_check_output=$(BLACKHOST_UPDATE_API_URL='https://example.invalid/latest' \
  "$ROOT/bin/blackhost" update --check)
unset -f curl
[[ "$update_check_output" == *"Zainstalowana"*"v1.1.0"* ]]
[[ "$update_check_output" == *"Najnowsza"*"v1.2.3"* ]]
[[ "$update_check_output" == *"Dostępna jest aktualizacja"* ]]
unknown_update_output=$("$ROOT/bin/blackhost" update --unknown 2>&1 || true)
[[ "$unknown_update_output" == *"Nieznana opcja aktualizacji"* ]]

release_source="$temp_dir/BlackHostCLI-v1.1.0"
mkdir -p "$release_source"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/modules" "$release_source/"
cp "$ROOT/install.sh" "$release_source/install.sh"
release_archive="$temp_dir/blackhost-v1.1.0.tar.gz"
tar -czf "$release_archive" -C "$temp_dir" 'BlackHostCLI-v1.1.0'
blackhost_update_validate_archive "$release_archive" '1.1.0' "$temp_dir/validated-release"
[[ "$(BLACKHOST_ROOT="$temp_dir/validated-release" \
  "$temp_dir/validated-release/bin/blackhost" version)" == 'blackhost 1.1.0' ]]

panel_info_fixture=$'+-----------------+--------+\n| Panel Version   | 1.12.3 |\n| Latest Version  | 1.12.4 |\n+-----------------+--------+'
[[ "$(pterodactyl_panel_info_value "Panel Version" "$panel_info_fixture")" == "1.12.3" ]]
[[ "$(pterodactyl_panel_info_value "Latest Version" "$panel_info_fixture")" == "1.12.4" ]]
[[ "$(pterodactyl_composer_major 'Composer version 2.8.10 2026-01-01')" == "2" ]]
[[ "$(pterodactyl_composer_major 'Composer version 1.10.27 2023-01-01')" == "1" ]]
[[ "$(pterodactyl_release_version_from_url 'https://github.com/pterodactyl/panel/releases/tag/v1.15.0')" == "1.15.0" ]]
! pterodactyl_release_version_from_url 'https://github.com/pterodactyl/panel/releases/latest'
grep -qF 'pterodactyl_panel_update_versions || return 0' "$ROOT/modules/pterodactyl.sh"

wings_fixture="$temp_dir/wings"
printf '%s\n' '#!/usr/bin/env bash' 'printf "wings v1.13.2\\n"' >"$wings_fixture"
chmod +x "$wings_fixture"
[[ "$(pterodactyl_wings_version "$wings_fixture")" == "1.13.2" ]]

printf '%s\n' '#!/usr/bin/env bash' 'printf "Version: v1.12.3 (linux/amd64)\\n" >&2' >"$wings_fixture"
[[ "$(pterodactyl_wings_version "$wings_fixture")" == "1.12.3" ]]

printf '%s\n' '#!/usr/bin/env bash' 'printf "wersja nieznana\\n"' >"$wings_fixture"
! pterodactyl_wings_version "$wings_fixture"

[[ $(grep -Fc 'ui_confirm "Rozpocząć instalację?" y' "$ROOT/modules/pterodactyl.sh") -eq 2 ]]
grep -qF 'ui_confirm "Dokończyć konfigurację panelu?" y' "$ROOT/modules/pterodactyl.sh"
grep -qF 'ui_confirm "Rozpocząć instalację Nginx?" y' "$ROOT/modules/nginx.sh"
grep -qF 'ui_confirm "Rozpocząć instalację Blueprinta?" y' "$ROOT/modules/blueprint.sh"
grep -qF 'USUN BLUEPRINT' "$ROOT/modules/blueprint.sh"
grep -qF 'pterodactyl_update_runtime_preflight false || return 1' "$ROOT/modules/blueprint.sh"
grep -qF 'run_with_progress "blueprint-uninstall" blueprint_uninstall_impl' "$ROOT/modules/blueprint.sh"
! sed -n '/^blueprint_uninstall()/,/^}/p' "$ROOT/modules/blueprint.sh" | grep -qF 'update_runtime_preflight'
! grep -qF 'BlackHost nie tworzy automatycznej kopii' "$ROOT/modules/pterodactyl.sh"
! grep -qF 'BlackHost nie tworzy automatycznej kopii' "$ROOT/modules/blueprint.sh"
! grep -qF 'ui_summary_row "Użytkownik WWW"' "$ROOT/modules/blueprint.sh"
! grep -qF 'ui_summary_row "Własność plików"' "$ROOT/modules/blueprint.sh"

blueprint_select_release <<<'1' >/dev/null
[[ "$BLUEPRINT_VERSION" == "beta-2026-05" ]]
[[ "$BLUEPRINT_SHA256" == "d61453bdee5f2aeca252ebae6564de8607055339761e7bdd629ea6b0394c4ac4" ]]
blueprint_select_release <<<'2' >/dev/null
[[ "$BLUEPRINT_VERSION" == "beta-2026-06" ]]
[[ "$BLUEPRINT_SHA256" == "60336dc7362ca922509ab9710a8d64442833920df48a601ce25197cf00ab4a90" ]]
! grep -qF 'NGINX_CONFIG_BACKUP' "$ROOT/modules/nginx.sh"
! grep -qF '/var/backups/blackhost' "$ROOT/install.sh"

original_blueprint_panel_dir=$BLUEPRINT_PANEL_DIR
BLUEPRINT_PANEL_DIR="$temp_dir/blueprint-panel"
mkdir -p "$BLUEPRINT_PANEL_DIR/.blueprint/extensions/blueprint/private/db"
touch "$BLUEPRINT_PANEL_DIR/.blueprint/extensions/blueprint/private/db/is_installed"
blueprint_installed
rm -f "$BLUEPRINT_PANEL_DIR/.blueprint/extensions/blueprint/private/db/is_installed"
! blueprint_installed
blueprint_files_present
BLUEPRINT_PANEL_DIR=$original_blueprint_panel_dir

nginx_fixture_dir="$temp_dir/nginx-version"
mkdir -p "$nginx_fixture_dir"
printf '%s\n' '#!/usr/bin/env bash' 'printf "nginx version: nginx/1.26.3\\n" >&2' >"$nginx_fixture_dir/nginx"
chmod +x "$nginx_fixture_dir/nginx"
hash -p "$nginx_fixture_dir/nginx" nginx
[[ "$(nginx_version)" == "1.26.3" ]]
hash -r

stale_nginx_dir="$temp_dir/stale-nginx"
mkdir -p "$stale_nginx_dir"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$stale_nginx_dir/nginx"
chmod +x "$stale_nginx_dir/nginx"
hash -p "$stale_nginx_dir/nginx" nginx
rm -f "$stale_nginx_dir/nginx"
! nginx_installed
hash -r

speedtest_fixture="$temp_dir/speedtest-result.log"
printf '%s\n' 'Server: Gigatrans PL - Warsaw (id: 12345)' >"$speedtest_fixture"
[[ "$(speedtest_parse_server "$speedtest_fixture")" == "Gigatrans PL - Warsaw" ]]

metric_output=$(ui_metric_value "WYSYŁANIE" "45.21" "Mbps")
[[ "$metric_output" == *"WYSYŁANIE        45.21 Mbps"* ]]

summary_output=$(ui_summary_row "E-mail techniczny" "admin@example.pl")
[[ "$summary_output" == "    E-mail techniczny  admin@example.pl" ]]
summary_output=$(ui_summary_row "Imię i nazwisko" "Admin Admin")
[[ "$summary_output" == "    Imię i nazwisko    Admin Admin" ]]
summary_output=$(ui_summary_row "Użytkownik" "pterodactyl")
[[ "$summary_output" == "    Użytkownik         pterodactyl" ]]
[[ "$(ui_state_value true)" == "Włączony" ]]
[[ "$(ui_state_value false)" == "Wyłączony" ]]

status_pause_output=$(printf '\n' | ui_pause escape)
[[ "$status_pause_output" == *"Naciśnij Enter lub Esc, aby wrócić..."* ]]
grep -qF '2) show_status; ui_pause escape ;;' "$ROOT/bin/blackhost"

BH_CONTENT_WIDTH=44
narrow_option=$(ui_option_render 1 "Zainstaluj Panel" "Bardzo długi opis, który nie może zawinąć wiersza" false)
[[ "${#narrow_option}" -eq 46 ]]
[[ "$narrow_option" != *$'\033[K'* ]]
BH_CONTENT_WIDTH=68

ascii_output=$(TERM=linux NO_COLOR=1 bash -c \
  'source "$1"; ui_info "Zażółć gęślą jaźń"' _ "$ROOT/lib/ui.sh")
[[ "$ascii_output" == "  i  Zazolc gesla jazn" ]]

ssh_highlight=$(SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22' bash -c \
  'source "$1"; printf "%s" "$BH_MENU_HIGHLIGHT"' _ "$ROOT/lib/ui.sh")
[[ "$ssh_highlight" == "false" ]]

BH_SCREEN_CLEAR=true
refresh_output=$(ui_refresh)
[[ "$refresh_output" == $'\033[H\033[2J' ]]
BH_SCREEN_CLEAR=false

link_output=$(ui_hyperlink "https://www.speedtest.net/result/c/test-id")
[[ "$link_output" == *"https://www.speedtest.net/result/c/test-id"* ]]

uninstaller_fixture="$temp_dir/upstream/installers"
mkdir -p "$uninstaller_fixture"
printf '%s\n' \
  'rm_database() {' \
  '  echo original' \
  '}' \
  >"$uninstaller_fixture/uninstall.sh"
PTERO_SOURCE_DIR="$temp_dir/upstream"
pterodactyl_prepare_managed_uninstaller
grep -qF 'BLACKHOST_DATABASE_MODE' "$uninstaller_fixture/uninstall.sh"
bash -n "$uninstaller_fixture/uninstall.sh"

valid_email "admin@example.com"
! valid_email "admin.example.com"
valid_db_identifier "ptero_panel_1"
! valid_db_identifier "ptero-panel"
valid_fqdn "panel.example.com"
! valid_fqdn "localhost"
valid_ipv4 "192.0.2.10"
! valid_ipv4 "999.0.2.10"

progress_log="$temp_dir/progress.log"
printf '%s\n' '* Installing cronjob..' >"$progress_log"
stage=$(progress_stage "pterodactyl-panel-install" "$progress_log" 55 "Migracje")
[[ "$stage" == "96|Konfiguracja zadań cron" ]]

printf '%s\n' \
  '1 upgraded, 3 newly installed, 0 to remove and 0 not upgraded.' \
  'Get:1 https://example.test package-one amd64 1.0 [10 kB]' \
  'Get:2 https://example.test package-two amd64 1.0 [10 kB]' \
  'Unpacking package-one (1.0) ...' \
  'Unpacking package-two (1.0) ...' \
  'Setting up package-one (1.0) ...' \
  >"$progress_log"
[[ "$(progress_package_stats "$progress_log")" == "4|2|2|1" ]]
stage=$(progress_stage "pterodactyl-panel-install" "$progress_log" 3 "Start")
[[ "$stage" == "54|Konfigurowanie pakietów (1/4)" ]]
rendered_progress=$(progress_render 54 "Konfigurowanie pakietów (1/4)" 9)
[[ "$rendered_progress" == *" 54%  Konfigurowanie pakietów (1/4)"* ]]
BH_CONTENT_WIDTH=44
narrow_progress=$(progress_render 54 "Konfigurowanie pakietów (1/4)" 9)
[[ "$narrow_progress" == *"(1/4)"* ]]
BH_CONTENT_WIDTH=68

printf '%s\n' '* Removing services...' >"$progress_log"
stage=$(progress_stage "pterodactyl-panel-uninstall" "$progress_log" 3 "Start")
[[ "$stage" == "82|Usuwanie usług panelu" ]]

printf '%s\n' '* Removing wings files...' >"$progress_log"
stage=$(progress_stage "pterodactyl-wings-uninstall" "$progress_log" 3 "Start")
[[ "$stage" == "68|Usuwanie Wings i danych serwerów" ]]

printf '%s\n' 'BlackHost stage: nginx service' >"$progress_log"
stage=$(progress_stage "nginx-install" "$progress_log" 3 "Start")
[[ "$stage" == "88|Uruchamianie usługi Nginx" ]]

printf '%s\n' 'BlackHost stage: nginx configuration cleanup' >"$progress_log"
stage=$(progress_stage "nginx-uninstall" "$progress_log" 3 "Start")
[[ "$stage" == "82|Obsługa konfiguracji Nginx" ]]

printf '%s\n' 'BlackHost stage: panel update composer' >"$progress_log"
stage=$(progress_stage "pterodactyl-panel-update" "$progress_log" 3 "Start")
[[ "$stage" == "50|Aktualizacja zależności PHP" ]]

printf '%s\n' 'BlackHost stage: wings update restart' >"$progress_log"
stage=$(progress_stage "pterodactyl-wings-update" "$progress_log" 3 "Start")
[[ "$stage" == "84|Uruchamianie Wings" ]]

grep -qF 'progress_title="POSTĘP AKTUALIZACJI"' "$ROOT/lib/core.sh"
grep -qF 'completion_label="Aktualizacja zakończona"' "$ROOT/lib/core.sh"

printf '%s\n' 'BlackHost stage: cli update checksum' >"$progress_log"
stage=$(progress_stage "blackhost-cli-update" "$progress_log" 3 "Start")
[[ "$stage" == "32|Weryfikacja sumy SHA-256" ]]

printf '%s\n' 'BlackHost stage: phpmyadmin certificate' >"$progress_log"
stage=$(progress_stage "phpmyadmin-install" "$progress_log" 3 "Start")
[[ "$stage" == "86|Pobieranie certyfikatu SSL" ]]

printf '%s\n' 'BlackHost stage: phpmyadmin update swap' >"$progress_log"
stage=$(progress_stage "phpmyadmin-update" "$progress_log" 3 "Start")
[[ "$stage" == "88|Aktywowanie nowej wersji" ]]

printf '%s\n' 'BlackHost stage: phpmyadmin uninstall files' >"$progress_log"
stage=$(progress_stage "phpmyadmin-uninstall" "$progress_log" 3 "Start")
[[ "$stage" == "58|Usuwanie plików phpMyAdmin" ]]

printf '%s\n' 'Rebuilding panel assets..' >"$progress_log"
stage=$(progress_stage "blueprint-install" "$progress_log" 3 "Start")
[[ "$stage" == "96|Przebudowa frontendu panelu" ]]

printf '%s\n' 'BlackHost stage: blueprint uninstall remove' >"$progress_log"
stage=$(progress_stage "blueprint-uninstall" "$progress_log" 3 "Start")
[[ "$stage" == "32|Usuwanie plików Blueprinta" ]]

(
  NGINX_PACKAGE_MANAGER=apt
  apt-get() { return 42; }
  ! nginx_install_impl >/dev/null
)

BLACKHOST_LOG_DIR="$temp_dir/logs"
mkdir -p "$BLACKHOST_LOG_DIR"
dummy_install() {
  printf 'test instalatora\n'
}
BLACKHOST_RAW_LOGS=1 run_with_progress "smoke-install" dummy_install >/dev/null
grep -qF 'test instalatora' "$BLACKHOST_LOG_DIR"/*.log

printf 'Smoke tests: OK\n'
