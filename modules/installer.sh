#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 BlackHost.pl

installer_menu() {
  local choice
  while :; do
    ui_header "INSTALATOR"
    ui_section "PROGRAMY"
    ui_option 1 "Pterodactyl" "Panel i Wings"
    ui_option 2 "Nginx" "Serwer WWW i reverse proxy"
    ui_option 0 "Wróć" "Menu główne"
    ui_menu_prompt choice

    case "$choice" in
      1) pterodactyl_menu ;;
      2) nginx_menu ;;
      0) return 0 ;;
      *) ui_error "Nieprawidłowa opcja."; sleep 1 ;;
    esac
  done
}
