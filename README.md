# BlackHost CLI

Interaktywne narzędzie administracyjne dla serwerów Linux. Polecenie `blackhost`
uruchamia terminalowe menu do instalacji, aktualizacji, naprawy i usuwania
popularnych usług hostingowych.

> [!WARNING]
> BlackHost CLI wykonuje operacje jako `root` i część jego funkcji może trwale
> usunąć usługi, bazy danych lub dane serwerów. Przed użyciem na środowisku
> produkcyjnym wykonaj własną kopię zapasową i przeczytaj podsumowanie operacji.

## Możliwości

- instalacja Pterodactyl Panel, Wings albo obu komponentów;
- aktualizacja, naprawa i pełne odinstalowanie Panelu oraz Wings;
- instalacja i odinstalowanie Blueprint Framework;
- instalacja i odinstalowanie Nginx z kontrolą zachowania konfiguracji;
- stan wykrytych usług;
- test łącza przez oficjalny pakiet Speedtest CLI firmy Ookla;
- czytelny postęp operacji i pełne logi w `/var/log/blackhost`;
- obsługa SSH, konsoli Linux/VNC, Unicode oraz trybu ASCII.

## Wymagania

- Linux z Bash 4 lub nowszym;
- konto `root` albo `sudo`;
- aktywne połączenie z Internetem;
- system i architektura wspierane przez wybrany instalator.

Integracja Pterodactyla korzysta obecnie z przypiętego wydania
`pterodactyl-installer v1.3.0` oraz weryfikuje pobrane archiwum sumą SHA-256.
Zakres wspieranych systemów wynika z tego wydania upstreamu. Panel wymaga
architektury `x86_64`; Wings obsługuje również `arm64`.

Blueprint jest obsługiwany dla natywnej instalacji Panelu na Debianie lub Ubuntu
z menedżerem pakietów APT.

## Instalacja

Sklonuj repozytorium, przejdź do katalogu projektu i uruchom instalator:

```bash
git clone https://github.com/BlackHost-PL/BlackHostCLI.git
cd BlackHostCLI
sudo bash install.sh
blackhost
```

Instalator kopiuje aplikację do `/opt/blackhost` i tworzy dowiązanie
`/usr/local/bin/blackhost`. Po udanej instalacji katalog ze sklonowanym
repozytorium można usunąć.

Aktualizacja CLI odbywa się przez pobranie nowszej wersji repozytorium i ponowne
uruchomienie `sudo bash install.sh`. Dane działania i logi nie są wtedy usuwane.

## Komendy

```text
blackhost              menu główne
blackhost installer    katalog instalatorów
blackhost pterodactyl  operacje Pterodactyla
blackhost nginx        operacje Nginx
blackhost status       stan wykrytych usług
blackhost speedtest    test łącza przez Speedtest CLI
blackhost version      wersja BlackHost CLI
blackhost help         pomoc
```

## Pliki programu

| Ścieżka | Zastosowanie |
| --- | --- |
| `/opt/blackhost` | zainstalowany kod CLI i dokumentacja |
| `/usr/local/bin/blackhost` | polecenie uruchamiające CLI |
| `/var/lib/blackhost` | stan działania programu |
| `/var/log/blackhost` | pełne logi instalacji i aktualizacji |

## Terminal

Menu automatycznie dobiera sposób wyświetlania do terminala. Dostępne są też
zmienne środowiskowe:

| Zmienna | Działanie |
| --- | --- |
| `BLACKHOST_ASCII=1` | wymusza tekst bez znaków Unicode |
| `BLACKHOST_UNICODE=1` | wymusza wariant Unicode |
| `BLACKHOST_FORCE_CLEAR=1` | wymusza pełne czyszczenie ekranu |
| `BLACKHOST_NO_ALT_SCREEN=1` | wyłącza alternatywny ekran terminala |
| `BLACKHOST_MENU_HIGHLIGHT=1` | włącza rozjaśnianie aktywnej pozycji |
| `NO_COLOR=1` | wyłącza kolory |

## Bezpieczeństwo

- jednocześnie może działać tylko jedna operacja instalacyjna;
- pobierane wydania instalatora Pterodactyla i Blueprinta są przypięte do
  konkretnej wersji i sumy SHA-256;
- hasła nie są zapisywane w stanie BlackHost ani celowo wypisywane do logów;
- aktualizator Panelu weryfikuje środowisko, strukturę archiwum i zachowuje `.env`;
- odinstalowanie Panelu i Wings korzysta z modułu odinstalowania upstreamu;
- destrukcyjne operacje wymagają wyraźnego potwierdzenia.

Znalezioną lukę zgłoś zgodnie z [SECURITY.md](SECURITY.md), a nie w publicznym
zgłoszeniu. Logi dołączane do zgłoszeń należy wcześniej pozbawić domen, adresów
IP, tokenów i innych danych prywatnych.

## Rozwój i testy

```bash
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash tests/smoke.sh
```

Opis budowy projektu znajduje się w [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
a zasady współpracy w [CONTRIBUTING.md](CONTRIBUTING.md).

## Licencja

Copyright (C) 2026 BlackHost.pl.

Kod BlackHost CLI jest udostępniany na licencji
[GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`). Można go używać,
modyfikować i rozpowszechniać, również komercyjnie, na warunkach tej licencji.
Zmodyfikowane wersje rozpowszechniane dalej muszą pozostać dostępne wraz z kodem
źródłowym na zgodnej licencji GPL.

Program korzysta z projektów zewnętrznych objętych ich własnymi warunkami.
Szczegóły i informacje o braku powiązania z ich autorami zawiera
[THIRD_PARTY.md](THIRD_PARTY.md).
