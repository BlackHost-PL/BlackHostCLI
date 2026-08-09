#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

set -Eeuo pipefail

[[ "$(uname -s)" == "Linux" ]] || {
  printf 'Instalator działa wyłącznie na Linuksie.\n' >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || {
  printf 'Uruchom instalator jako root: sudo bash install.sh\n' >&2
  exit 1
}

SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_ROOT="${BLACKHOST_INSTALL_ROOT:-/opt/blackhost}"
BIN_LINK="${BLACKHOST_BIN_LINK:-/usr/local/bin/blackhost}"

install -d -m 755 "$INSTALL_ROOT" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib" "$INSTALL_ROOT/modules" "$INSTALL_ROOT/docs"
install -m 755 "$SOURCE_ROOT/bin/blackhost" "$INSTALL_ROOT/bin/blackhost"
install -m 644 "$SOURCE_ROOT/lib/core.sh" "$INSTALL_ROOT/lib/core.sh"
install -m 644 "$SOURCE_ROOT/lib/ui.sh" "$INSTALL_ROOT/lib/ui.sh"
for module_file in "$SOURCE_ROOT"/modules/*.sh; do
  install -m 644 "$module_file" "$INSTALL_ROOT/modules/$(basename "$module_file")"
done
install -m 644 "$SOURCE_ROOT/README.md" "$INSTALL_ROOT/README.md"
install -m 644 "$SOURCE_ROOT/LICENSE" "$INSTALL_ROOT/LICENSE"
install -m 644 "$SOURCE_ROOT/THIRD_PARTY.md" "$INSTALL_ROOT/THIRD_PARTY.md"
install -m 644 "$SOURCE_ROOT/docs/ARCHITECTURE.md" "$INSTALL_ROOT/docs/ARCHITECTURE.md"

ln -sfn "$INSTALL_ROOT/bin/blackhost" "$BIN_LINK"
install -d -m 700 /var/lib/blackhost
install -d -m 750 /var/log/blackhost

printf 'Zainstalowano BlackHost CLI. Uruchom poleceniem: blackhost\n'
