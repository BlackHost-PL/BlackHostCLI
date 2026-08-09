# Architektura BlackHost CLI

## Założenie

`blackhost` jest małym, niezależnym narzędziem administracyjnym dla świeżych
serwerów Linux. Nie zależy od Dashboardu ani od kodu panelu Pterodactyl.

## Warstwy

- `bin/blackhost` — router komend i główne menu;
- `lib/ui.sh` — wspólne kolory, pytania i potwierdzenia;
- `lib/core.sh` — root/preflight, blokada operacji, logi, stan i walidacja;
- `modules/installer.sh` — katalog programów i wejście do ich akcji;
- `modules/*.sh` — niezależne adaptery usług;
- `/var/lib/blackhost` — niewrażliwy stan wykonanych operacji;
- `/var/log/blackhost` — logi instalacji bez wartości wpisywanych w ukrytych polach;

Interaktywne menu korzysta ze standardowego alternatywnego bufora terminala
(`smcup`/`rmcup`). Odświeżanie nie czyści historii sesji SSH, a wyjście z CLI
przywraca ekran sprzed uruchomienia. Przy braku TTY lub obsługi `terminfo`
interfejs przechodzi w tryb liniowy bez wywoływania `clear`.

## Kontrakt modułu

Każdy moduł powinien udostępniać co najmniej funkcje `status`, `install`,
`uninstall` i własne menu. Instalacja musi być idempotentna na poziomie
preflight: wykryta istniejąca instalacja jest zatrzymywana zamiast nadpisywana.

## Zewnętrzne instalatory

Nie wykonujemy bezpośrednio `bash <(curl ...)`. Najpierw pobierane jest
konkretne wydanie, sprawdzana jest SHA-256, a następnie uruchamiany jest jego
wewnętrzny instalator z jawnie przekazanymi zmiennymi środowiskowymi. Dzięki
temu menu BlackHost nie zależy od kolejności pytań w cudzym skrypcie.

Adapter Pterodactyla jest obecnie przypięty do `pterodactyl-installer v1.3.0`.
Aktualizacja wymaga przeglądu zmian, testu na czystej maszynie i zmiany wersji
oraz sumy w jednym miejscu.

Wersja zainstalowanego Panelu jest odczytywana z `config/app.php`, z awaryjnym
odczytem przez `php artisan p:info`. Aktualizacja Panelu nie korzysta z
nieaktywnego obecnie mechanizmu self-upgrade. Adapter realizuje oficjalną
procedurę ręczną: pobranie najnowszego stabilnego archiwum, maintenance mode,
Composer, czyszczenie cache, migracje, właściciel plików, restart kolejki i
ponowne uruchomienie Panelu. Wykryty Blueprint jest ponownie nakładany przez
`blueprint -upgrade`. Kopia zapasowa pozostaje świadomą decyzją administratora.

Najnowsza wersja Panelu i Wings jest ustalana przez docelowy adres oficjalnego
przekierowania GitHub `/releases/latest`. Panel pobiera następnie archiwum z
konkretnego tagu, dzięki czemu sprawdzana i instalowana wersja nie mogą się
rozjechać. Wings aktualizuje osobną binarkę dla `amd64` lub `arm64`, weryfikuje
jej wbudowany numer wersji i zachowuje poprzednią binarkę wyłącznie w `/tmp` na
czas restartu oraz ewentualnego rollbacku.

Odinstalowanie Blueprinta realizuje procedurę projektu: najpierw pobiera i
weryfikuje czyste wydanie Panelu, następnie w maintenance mode usuwa nieukryte
pliki zmodyfikowane przez framework oraz `.blueprint`, `.blueprintrc` i jego
polecenie systemowe. Plik `.env` pozostaje na miejscu, po czym ten sam mechanizm
aktualizacji odtwarza Panel, zależności, migracje, własność plików i kolejkę.

Adapter Blueprinta instaluje wybrane, przypięte wydanie frameworka na natywnym
Panelu Pterodactyl w systemie z APT. Użytkownik może wybrać wydanie najnowsze
albo oznaczone przez Blueprint jako wspierane; oba archiwa mają niezależne sumy
SHA-256. Użytkownik serwera WWW jest wykrywany z własności katalogu `storage`.

## Usuwanie

Usuwanie delegowane jest bezpośrednio do funkcji `perform_uninstall` z
przypiętego wydania pterodactyl-installer. Decyzje o usunięciu bazy i użytkownika
Panelu zbiera po polsku BlackHost, a następnie przekazuje je do funkcji upstreamu.
Wings usuwa dane w `/var/lib/pterodactyl` i wykonuje `docker system prune -a -f`.
Przed uruchomieniem wymagane jest wpisanie jawnej frazy potwierdzającej zakres
operacji.
