## Opis zmiany

<!-- Krótko opisz problem i zastosowane rozwiązanie. -->

## Rodzaj zmiany

- [ ] Naprawa błędu
- [ ] Nowa funkcja
- [ ] Zmiana istniejącego zachowania
- [ ] Dokumentacja lub testy
- [ ] Utrzymanie projektu

## Weryfikacja

<!-- Podaj system testowy i opisz wykonane testy. -->

- [ ] Sprawdziłem składnię wszystkich skryptów poleceniem:
      `find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n`
- [ ] Uruchomiłem `bash tests/smoke.sh`
- [ ] Sprawdziłem zmianę na obsługiwanym systemie Linux lub wyjaśniłem, dlaczego nie było to potrzebne

## Lista kontrolna

- [ ] Komunikaty interfejsu są po polsku i działają w trybie ASCII
- [ ] Operacje destrukcyjne pokazują zakres i wymagają potwierdzenia
- [ ] Nowe pobierane artefakty mają przypiętą wersję i sumę SHA-256
- [ ] Zmiana nie zawiera sekretów, prywatnych domen, adresów IP ani pełnych logów serwera
- [ ] Dokumentacja i testy zostały zaktualizowane, jeśli zmiana tego wymaga

## Wpływ na istniejące instalacje

<!-- Opisz zgodność wsteczną, wymagane kroki aktualizacji albo wpisz „Brak”. -->
