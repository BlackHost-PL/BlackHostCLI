# Współtworzenie BlackHost CLI

Dziękujemy za chęć rozwijania projektu. Przed rozpoczęciem większej zmiany warto
otworzyć zgłoszenie i opisać proponowane zachowanie.

## Zgłaszanie zmian

1. Utwórz fork i osobną gałąź dla zmiany.
2. Nie dodawaj sekretów, prywatnych domen, adresów IP ani pełnych logów serwera.
3. Zachowaj zgodność z Bash 4+ i nie uzależniaj podstawowego menu od narzędzi,
   których instalator sam nie zapewnia.
4. Dodaj lub zaktualizuj testy dla zmienianego zachowania.
5. Uruchom lokalną weryfikację:

   ```bash
   find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
   bash tests/smoke.sh
   ```

6. W pull requeście opisz system testowy, wykonane testy i wpływ na istniejące
   instalacje.

## Styl

- wcięcie: dwie spacje;
- zakończenia linii: LF;
- kod i komentarze powinny być zrozumiałe bez znajomości historii projektu;
- komunikaty interfejsu pisz po polsku i dodawaj wariant zgodny z trybem ASCII;
- pobierane artefakty przypinaj do wersji i sumy SHA-256;
- operacje destrukcyjne muszą pokazywać zakres i wymagać potwierdzenia.

Wkład do projektu jest udostępniany na warunkach `GPL-3.0-only`, takich samych
jak pozostały kod BlackHost CLI.
