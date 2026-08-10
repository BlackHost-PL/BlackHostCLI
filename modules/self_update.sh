#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

BLACKHOST_UPDATE_REPOSITORY="${BLACKHOST_UPDATE_REPOSITORY:-BlackHost-PL/BlackHostCLI}"
BLACKHOST_UPDATE_API_URL="${BLACKHOST_UPDATE_API_URL:-https://api.github.com/repos/${BLACKHOST_UPDATE_REPOSITORY}/releases/latest}"
BLACKHOST_UPDATE_RELEASES_URL="${BLACKHOST_UPDATE_RELEASES_URL:-https://github.com/${BLACKHOST_UPDATE_REPOSITORY}/releases/download}"
BLACKHOST_INSTALL_ROOT="${BLACKHOST_INSTALL_ROOT:-/opt/blackhost}"
BLACKHOST_BIN_LINK="${BLACKHOST_BIN_LINK:-/usr/local/bin/blackhost}"

blackhost_release_version_from_tag() {
  local version=${1#v}
  [[ "$1" == "v${version}" ]] || return 1
  [[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || return 1
  printf '%s' "$version"
}

blackhost_version_is_newer() {
  local candidate=$1 current=$2
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch

  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r current_major current_minor current_patch <<<"$current"
  [[ "$candidate_major" =~ ^[0-9]+$ && "$candidate_minor" =~ ^[0-9]+$ \
    && "$candidate_patch" =~ ^[0-9]+$ && "$current_major" =~ ^[0-9]+$ \
    && "$current_minor" =~ ^[0-9]+$ && "$current_patch" =~ ^[0-9]+$ ]] || return 1

  ((10#$candidate_major > 10#$current_major)) && return 0
  ((10#$candidate_major < 10#$current_major)) && return 1
  ((10#$candidate_minor > 10#$current_minor)) && return 0
  ((10#$candidate_minor < 10#$current_minor)) && return 1
  ((10#$candidate_patch > 10#$current_patch))
}

blackhost_release_tag_from_json() {
  tr ',' '\n' \
    | sed -nE 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n 1
}

blackhost_update_curl() {
  local output=${1:-} url=$2
  local -a arguments=(--fail --location --silent --show-error)

  if [[ "$url" == https://* ]]; then
    arguments+=(--proto '=https' --tlsv1.2)
  elif [[ "${BLACKHOST_UPDATE_TEST_MODE:-0}" != "1" ]]; then
    ui_error "Aktualizator odrzucił adres bez HTTPS."
    return 1
  fi

  [[ -n "$output" ]] && arguments+=(--output "$output")
  curl "${arguments[@]}" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --user-agent "BlackHostCLI/${BLACKHOST_VERSION}" \
    "$url"
}

blackhost_latest_release_version() {
  local response tag version
  response=$(blackhost_update_curl "" "$BLACKHOST_UPDATE_API_URL") || return 1
  tag=$(printf '%s' "$response" | blackhost_release_tag_from_json)
  version=$(blackhost_release_version_from_tag "$tag") || {
    ui_error "Najnowsze wydanie ma nieobsługiwany tag: ${tag:-brak}."
    return 1
  }
  printf '%s' "$version"
}

blackhost_update_checksum_from_file() {
  local checksum_file=$1 archive_name=$2 hash listed_name
  while read -r hash listed_name _; do
    listed_name=${listed_name#\*}
    if [[ "$listed_name" == "$archive_name" && "$hash" =~ ^[0-9A-Fa-f]{64}$ ]]; then
      printf '%s' "${hash,,}"
      return 0
    fi
  done <"$checksum_file"
  return 1
}

blackhost_update_remove_temp_dir() {
  local target=${1:-}
  [[ -n "$target" && -d "$target" && "$(basename "$target")" == blackhost-self-update.* ]] || return 1
  rm -rf -- "$target"
}

blackhost_update_remove_generated_dir() {
  local target=${1:-} install_root=${2%/} parent base
  parent=$(dirname "$install_root")
  base=$(basename "$install_root")
  case "$target" in
    "$parent/.${base}.update-"*|"$parent/.${base}.rollback-"*) rm -rf -- "$target" ;;
    *) return 1 ;;
  esac
}

blackhost_update_validate_archive() {
  local archive=$1 version=$2 staging=$3 entry expected_prefix embedded_version script_file
  local listing="${staging}.listing"
  expected_prefix="BlackHostCLI-v${version}"

  tar -tzf "$archive" >"$listing" || return 1
  while IFS= read -r entry; do
    [[ "$entry" == "$expected_prefix" || "$entry" == "$expected_prefix/"* ]] || return 1
    [[ "$entry" != /* && "/$entry/" != *"/../"* ]] || return 1
  done <"$listing"

  tar -tvzf "$archive" \
    | awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") bad = 1 } END { exit bad }' \
    || return 1

  mkdir -p "$staging"
  tar -xzf "$archive" -C "$staging" --strip-components=1 || return 1

  for script_file in \
    "$staging/install.sh" \
    "$staging/bin/blackhost" \
    "$staging/lib/core.sh" \
    "$staging/lib/ui.sh" \
    "$staging/modules/installer.sh" \
    "$staging/modules/self_update.sh"
  do
    [[ -f "$script_file" && ! -L "$script_file" ]] || return 1
  done

  while IFS= read -r -d '' script_file; do
    bash -n "$script_file" || return 1
  done < <(find "$staging" -type f -name '*.sh' -print0)

  embedded_version=$(BLACKHOST_ROOT="$staging" NO_COLOR=1 "$staging/bin/blackhost" version) || return 1
  [[ "$embedded_version" == "blackhost ${version}" ]]
}

blackhost_update_install_release() {
  local version=$1 temp_dir archive_name archive checksum_file expected_hash actual_hash staging
  local install_root=${BLACKHOST_INSTALL_ROOT%/} install_parent install_base new_root backup_root
  local validation_link had_current=false installed_version

  [[ "$install_root" == /* && "$install_root" != "/" ]] || {
    printf 'Nieprawidłowy katalog instalacji: %s\n' "$install_root" >&2
    return 1
  }

  install_parent=$(dirname "$install_root")
  install_base=$(basename "$install_root")
  temp_dir=$(mktemp -d /tmp/blackhost-self-update.XXXXXX) || return 1
  archive_name="blackhost-v${version}.tar.gz"
  archive="${temp_dir}/${archive_name}"
  checksum_file="${archive}.sha256"
  staging="${temp_dir}/source"
  new_root="${install_parent}/.${install_base}.update-${version}-$$"
  backup_root="${install_parent}/.${install_base}.rollback-$(date +%Y%m%d%H%M%S)-$$"
  validation_link="${temp_dir}/blackhost"

  trap 'blackhost_update_remove_generated_dir "$new_root" "$install_root" 2>/dev/null || true; blackhost_update_remove_temp_dir "$temp_dir" 2>/dev/null || true; exit 130' INT TERM HUP

  printf 'BlackHost stage: cli update download\n'
  blackhost_update_curl "$archive" "${BLACKHOST_UPDATE_RELEASES_URL}/v${version}/${archive_name}" || {
    printf 'Nie udało się pobrać wydania v%s.\n' "$version" >&2
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }
  blackhost_update_curl "$checksum_file" "${BLACKHOST_UPDATE_RELEASES_URL}/v${version}/${archive_name}.sha256" || {
    printf 'Nie udało się pobrać sumy SHA-256 wydania v%s.\n' "$version" >&2
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }

  printf 'BlackHost stage: cli update checksum\n'
  expected_hash=$(blackhost_update_checksum_from_file "$checksum_file" "$archive_name") || {
    printf 'Plik sumy kontrolnej ma nieprawidłowy format.\n' >&2
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }
  actual_hash=$(sha256sum "$archive" | awk '{print tolower($1)}')
  [[ "$actual_hash" == "$expected_hash" ]] || {
    printf 'Suma SHA-256 pobranego wydania jest nieprawidłowa.\n' >&2
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }

  printf 'BlackHost stage: cli update validate\n'
  blackhost_update_validate_archive "$archive" "$version" "$staging" || {
    printf 'Archiwum wydania nie przeszło walidacji.\n' >&2
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }

  [[ ! -e "$new_root" && ! -L "$new_root" && ! -e "$backup_root" && ! -L "$backup_root" ]] || {
    printf 'Tymczasowy katalog aktualizacji już istnieje.\n' >&2
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }

  printf 'BlackHost stage: cli update install\n'
  BLACKHOST_INSTALL_ROOT="$new_root" \
    BLACKHOST_BIN_LINK="$validation_link" \
    BLACKHOST_STATE_DIR="$BLACKHOST_STATE_DIR" \
    BLACKHOST_LOG_DIR="$BLACKHOST_LOG_DIR" \
    bash "$staging/install.sh" >/dev/null || {
      printf 'Instalacja nowego wydania nie powiodła się.\n' >&2
      blackhost_update_remove_generated_dir "$new_root" "$install_root" 2>/dev/null || true
      blackhost_update_remove_temp_dir "$temp_dir"
      trap - INT TERM HUP
      return 1
    }

  installed_version=$(BLACKHOST_ROOT="$new_root" NO_COLOR=1 "$new_root/bin/blackhost" version) || true
  [[ "$installed_version" == "blackhost ${version}" ]] || {
    printf 'Nowa instalacja zgłasza nieprawidłową wersję.\n' >&2
    blackhost_update_remove_generated_dir "$new_root" "$install_root"
    blackhost_update_remove_temp_dir "$temp_dir"
    trap - INT TERM HUP
    return 1
  }

  printf 'BlackHost stage: cli update swap\n'
  trap '' INT TERM HUP
  if [[ -e "$install_root" || -L "$install_root" ]]; then
    [[ -d "$install_root" && ! -L "$install_root" ]] || {
      printf 'Docelowa instalacja nie jest zwykłym katalogiem.\n' >&2
      trap - INT TERM HUP
      blackhost_update_remove_generated_dir "$new_root" "$install_root"
      blackhost_update_remove_temp_dir "$temp_dir"
      return 1
    }
    mv -- "$install_root" "$backup_root" || {
      trap - INT TERM HUP
      blackhost_update_remove_generated_dir "$new_root" "$install_root"
      blackhost_update_remove_temp_dir "$temp_dir"
      return 1
    }
    had_current=true
  fi

  if ! mv -- "$new_root" "$install_root"; then
    [[ "$had_current" == true ]] && mv -- "$backup_root" "$install_root"
    trap - INT TERM HUP
    blackhost_update_remove_temp_dir "$temp_dir"
    return 1
  fi

  if ! ln -sfn "$install_root/bin/blackhost" "$BLACKHOST_BIN_LINK" \
    || ! installed_version=$(BLACKHOST_ROOT="$install_root" NO_COLOR=1 "$install_root/bin/blackhost" version) \
    || [[ "$installed_version" != "blackhost ${version}" ]]; then
    mv -- "$install_root" "$new_root" || true
    [[ "$had_current" == true ]] && mv -- "$backup_root" "$install_root"
    [[ "$had_current" == true ]] && ln -sfn "$install_root/bin/blackhost" "$BLACKHOST_BIN_LINK" || true
    trap - INT TERM HUP
    blackhost_update_remove_generated_dir "$new_root" "$install_root" 2>/dev/null || true
    blackhost_update_remove_temp_dir "$temp_dir"
    printf 'Weryfikacja po aktualizacji nie powiodła się. Przywrócono poprzednią wersję.\n' >&2
    return 1
  fi
  trap - INT TERM HUP

  [[ "$had_current" == true ]] \
    && blackhost_update_remove_generated_dir "$backup_root" "$install_root"
  blackhost_update_remove_temp_dir "$temp_dir"
  printf 'BlackHost stage: cli update complete\n'
}

blackhost_update_check() {
  local latest_version
  ui_header "AKTUALIZACJA CLI"
  ui_section "WERSJE"
  ui_summary_row "Zainstalowana" "v${BLACKHOST_VERSION}"

  latest_version=$(blackhost_latest_release_version) || {
    ui_error "Nie udało się sprawdzić najnowszego wydania BlackHost CLI."
    return 1
  }
  ui_summary_row "Najnowsza" "v${latest_version}"
  BLACKHOST_LATEST_VERSION=$latest_version

  if [[ "$latest_version" == "$BLACKHOST_VERSION" ]]; then
    ui_success "BlackHost CLI jest aktualny."
    return 2
  fi
  if ! blackhost_version_is_newer "$latest_version" "$BLACKHOST_VERSION"; then
    ui_warn "Zainstalowana wersja jest nowsza niż ostatnie stabilne wydanie."
    return 2
  fi
  ui_info "Dostępna jest aktualizacja do v${latest_version}."
  return 0
}

blackhost_self_update() {
  local mode=${1:-} check_status=0
  case "$mode" in
    ""|--check|--yes|-y) ;;
    *)
      ui_error "Nieznana opcja aktualizacji: $mode"
      return 2
      ;;
  esac

  blackhost_update_check || check_status=$?
  [[ "$check_status" -eq 0 ]] || {
    [[ "$check_status" -eq 2 ]] && return 0
    return "$check_status"
  }

  [[ "$mode" == "--check" ]] && return 0
  require_linux || return 1
  require_root || return 1
  require_commands curl sha256sum tar awk sed tr head find bash install ln mv rm mkdir mktemp flock || return 1
  ensure_runtime_dirs || return 1
  acquire_operation_lock || return 1

  ui_section "ZAKRES"
  ui_summary_row "Aktualizacja" "v${BLACKHOST_VERSION} -> v${BLACKHOST_LATEST_VERSION}"
  ui_summary_row "Instalacja" "$BLACKHOST_INSTALL_ROOT"
  ui_info "Nowe pliki zostaną sprawdzone przed podmianą. Błąd uruchomi rollback."

  if [[ "$mode" != "--yes" && "$mode" != "-y" ]]; then
    ui_confirm "Zaktualizować BlackHost CLI?" n || {
      ui_info "Aktualizacja anulowana."
      return 0
    }
  fi

  if ! run_with_progress "blackhost-cli-update" blackhost_update_install_release "$BLACKHOST_LATEST_VERSION"; then
    ui_error "Nie udało się zaktualizować BlackHost CLI."
    return 1
  fi
  BLACKHOST_UPDATE_APPLIED=true
  ui_success "BlackHost CLI został zaktualizowany do v${BLACKHOST_LATEST_VERSION}."
  ui_info "Uruchom ponownie polecenie blackhost, aby korzystać z nowej wersji."
}
