# Jak pracować nad zadaniami (przewodnik krok po kroku)

Ten dokument jest dla osoby, która przejmuje pracę i nie wie, od czego zacząć.
Szczegóły każdego zadania są w issue na GitHubie — zacznij od epica **#19**.

## 1. Co budujemy — w trzech zdaniach

1. Mamy kilka serwerów (maszyn) w różnych miejscach. Chcemy, żeby rozmawiały ze sobą przez prywatny, szyfrowany
   „tunel” (WireGuard) i żeby dało się je postawić od zera jednym poleceniem.
2. **Kreator** (`wizard.sh`) to program, który zadaje pytania („ile masz maszyn?”, „co ma działać na której?”)
   i na tej podstawie przygotowuje **paczkę** dla każdej maszyny: skrypty, hasła, klucze, certyfikaty.
3. Paczkę kopiujesz na maszynę i uruchamiasz `sudo ./install.sh`. Skrypt instaluje wszystko po kolei.

Porównanie: kreator to kucharz, który pisze przepisy i pakuje składniki do pudełek. `install.sh` to osoba,
która w swojej kuchni (na serwerze) otwiera pudełko i gotuje według przepisu.

## 2. Słowniczek

| Słowo | Co to znaczy po ludzku |
| :--- | :--- |
| maszyna / VPS | jeden serwer (komputer w internecie albo maszyna wirtualna w VirtualBox) |
| edge | jedyna maszyna widoczna z internetu; „brama”, przez którą wchodzi ruch z zewnątrz; zawsze ma adres `10.100.10.100` |
| WireGuard (WG) | prywatna sieć między maszynami; każda dostaje adres `10.100.10.x` |
| peer | „uczestnik” sieci WireGuard: maszyna albo urządzenie administratora (laptop, telefon) |
| pełna siatka (mesh) | każda maszyna zna każdą inną (nie ma jednego „szefa” sieci) |
| usługa | program działający na maszynie, np. PostgreSQL, Traefik |
| katalog usług | folder `catalog/` — każda usługa ma w nim swój podfolder z opisem `service.conf` |
| `service.conf` | „wizytówka” usługi: jak się nazywa, gdzie może działać, jakie porty i hasła potrzebuje |
| compose | uruchamianie usługi w Dockerze (`docker compose`) |
| k3s | mały Kubernetes; uruchamia aplikacje, którymi zarządza ArgoCD |
| runtime | sposób uruchamiania na maszynie: `compose` albo `k3s` |
| priorytet | liczba w `service.conf`; im mniejsza, tym wcześniej usługa się instaluje |
| krok instalacji | jeden plik w `common/` (np. `02-wireguard.sh`), który robi jedną rzecz na serwerze |
| znacznik (marker) | pusty plik w `/var/lib/homelab/done/`, który mówi „ten krok już zrobiony, nie powtarzaj” |
| idempotentny | można uruchomić 10 razy i efekt jest taki sam jak po 1 razie |
| `--dry-run` | „na niby”: skrypt tylko wypisuje, co by zrobił, nic nie zmienia |
| `--force` | „zrób jeszcze raz”, nawet jeśli znacznik mówi, że już zrobione |
| `state.yaml` | „zeszyt” kreatora: lista maszyn, adresów i usług; dzięki niemu można później dodać maszynę |
| CA (urząd certyfikacji) | nasz własny „urząd”, który wystawia certyfikaty HTTPS dla adresów `*.homelab.internal` |
| sekret | hasło, klucz albo token; **nigdy** nie trafia do Gita |
| bats | narzędzie do testów skryptów Bash; testy są w `tests/unit/*.bats` |
| test golden | „wzorcowy wynik”: zapisujemy, co kreator powinien wygenerować, i porównujemy z tym, co generuje naprawdę |

## 3. Jak wygląda repozytorium

```
wizard.sh          # kreator (jeszcze go nie ma — powstaje w #9)
lib/               # funkcje kreatora: catalog.sh (jest), state.sh, secrets.sh, wg.sh, ca.sh, ui.sh, render.sh (do zrobienia)
common/lib.sh      # funkcje dla kroków instalacji: run, step, log_*, load_env (jest)
common/0*.sh 1*.sh # kroki instalacji (do zrobienia w #11, #12)
catalog/<id>/      # usługi: na razie tylko service.conf dla kilku usług
scripts/dev.sh     # polecenia deweloperskie: lint, test, golden, validate, container
tests/unit/        # testy bats
tests/fixtures/    # przykładowe dane do testów (np. mały katalog usług)
docs/              # architektura.md, plan-instalacji.md, ten plik
out/               # wynik kreatora — NIGDY nie commitujemy
```

Co już działa:

- `common/lib.sh` — `run` (wykonuje komendę albo ją wypisuje przy `--dry-run`), `step` (znaczniki
  idempotencji), `log_info`/`log_warn`/`log_error`, `die`, `require_root`, `load_env`.
- `lib/catalog.sh` — wczytanie i walidacja `catalog/*/service.conf`, a potem: `catalog_forced`
  (usługi obowiązkowe dla maszyny), `catalog_selectable` (usługi do wyboru), `catalog_expand`
  (dokłada usługi `AUTO_ADD`, np. eksportery), `catalog_missing_requires`, `catalog_sort` (po priorytecie).
- Testy bats dla obu plików.

## 4. Przygotowanie laptopa (raz)

```bash
sudo apt install git shellcheck shfmt bats wireguard-tools qrencode openssl whiptail
```

Tych narzędzi nie ma w paczkach Debiana pod właściwą nazwą — pobierz je z GitHub Releases
i wrzuć do `~/.local/bin` (sprawdź, czy ten katalog jest w `PATH`):

- `yq` — **mikefarah/yq** (nie pakiet `yq` z Debiana, to inny program): https://github.com/mikefarah/yq/releases
- `step` — step-cli: https://github.com/smallstep/cli/releases
- `kubeconform`: https://github.com/yannh/kubeconform/releases
- `docker` z wtyczką `compose` — do `scripts/dev.sh validate` i `container`.

Sprawdzenie: `yq --version` powinno wypisać `mikefarah`.

## 5. Jak zrobić jedno zadanie — przepis

1. **Wybierz zadanie.** Otwórz epic #19 i weź pierwsze nieodhaczone zadanie, którego wszystkie
   „Zależności” są już zamknięte. Kolejność w epicu jest dobra — trzymaj się jej.
2. **Przeczytaj issue do końca**, a potem fragmenty `docs/plan-instalacji.md` i `docs/architektura.md`,
   które issue wskazuje. Decyzji z tabeli „Decyzje” w planie instalacji nie zmieniamy.
3. **Zrób gałąź od świeżego `main`:**
   ```bash
   git checkout main && git pull
   git checkout -b feat/<numer-issue>-<krótka-nazwa>     # np. feat/5-state
   ```
4. **Pisz małymi kawałkami.** Jedna funkcja → jeden test → uruchom testy. Nie pisz wszystkiego naraz.
   - Logika idzie do `lib/<coś>.sh` jako funkcje. Funkcja nie może pytać użytkownika (`read`, `whiptail`)
     ani wymagać roota — wtedy da się ją przetestować.
   - Każdy skrypt zaczyna się od `#!/usr/bin/env bash` i `set -Eeuo pipefail` (pliki z samymi funkcjami,
     ładowane przez `source`, mają zamiast tego `# shellcheck shell=bash` — patrz `lib/catalog.sh`).
   - Komendy, które zmieniają system, wywołuj przez `run ...`, a nie bezpośrednio.
5. **Napisz testy bats** w `tests/unit/<coś>.bats`. Wzoruj się na `tests/unit/catalog.bats`
   i `tests/unit/helpers.bash` (np. `in_catalog '...'` uruchamia kod w osobnym bashu).
6. **Sprawdź, czy wszystko jest zielone:**
   ```bash
   scripts/dev.sh lint test
   ```
   Jeśli `shfmt` marudzi o formatowanie, popraw automatycznie: `shfmt -w -i 2 -ci <plik>`.
7. **Commit** w formacie Conventional Commits, po angielsku, np.:
   ```bash
   git add lib/state.sh tests/unit/state.bats tests/fixtures/state/
   git commit -m "feat(state): add state.yaml model and WG address allocation"
   ```
8. **Push i PR:**
   ```bash
   git push -u origin feat/5-state
   gh pr create --fill --body "Closes #5"
   ```
   `Closes #5` sprawia, że issue zamknie się samo po scaleniu PR.
9. **Po scaleniu PR odhacz** zadanie w epicu #19 (edytuj opis epica i zmień `- [ ]` na `- [x]`).

## 6. Zasady bezpieczeństwa — przeczytaj koniecznie

- **Nigdy nie uruchamiaj `install.sh` ani `common/0*.sh`, `common/1*.sh` na swoim laptopie bez `--dry-run`.**
  Te skrypty zmieniają firewall, SSH i sieć — możesz stracić internet albo dostęp do komputera.
  Bezpiecznie: `bash common/03-ufw.sh --dry-run` albo w kontenerze (`scripts/dev.sh container`, zadanie #13).
- Kreator (`wizard.sh`) możesz uruchamiać spokojnie — pisze tylko do `out/`.
- Nigdy nie commituj: `out/`, plików `*.key`, `secrets.env`, haseł. `.gitignore` to blokuje, ale sprawdzaj
  `git status` przed commitem.
- Porty usług zawsze na adresie WireGuard (`10.100.10.x`), nigdy `0.0.0.0`. Wyjątek: Traefik na edge (80/443).

## 7. Mapa zadań i zależności

Strzałka `A → B` znaczy: „B można zacząć dopiero, gdy A jest skończone”.

```
#5 stan (state.yaml)
 ├─→ #6 hasła ─────────────┐
 ├─→ #7 WireGuard ─────────┤
 └─→ #8 certyfikaty (CA) ──┤
                           ▼
                     #9 pytania kreatora (UI)
                           ▼
                     #10 paczki + testy golden
                           ▼
                     #11 kroki 00–04 (system, WG, firewall, CA)
                           ▼
                     #12 kroki 10–12 (Docker, k3s, node_exporter)
                           ├─→ #13 testy w kontenerze
                           ├─→ #14 CoreDNS + step-ca ─→ #15 Traefik
                           ├─→ #16 bazy danych
                           └─→ #17 OpenBao ─→ #18 ArgoCD
```

Zadania #6, #7 i #8 są od siebie niezależne — można je robić w dowolnej kolejności.
Podobnie #13, #14, #16 i #17 po skończeniu #12.

## 8. Gdy utkniesz

- Test nie przechodzi i nie wiesz czemu: `bats -x tests/unit/<plik>.bats` pokazuje każdą wykonaną linię.
- Nie wiesz, jak coś ma działać: szukaj w `docs/plan-instalacji.md` (Ctrl+F po nazwie usługi albo kroku).
- Coś w opisie issue jest sprzeczne z dokumentami: dokumenty `docs/` wygrywają; dopisz komentarz w issue.
- Kończy Ci się czas: zapisz, gdzie jesteś, w komentarzu do issue (co zrobione, co dalej, co nie działa)
  i wypchnij gałąź (`git push`), nawet jeśli nie jest skończona.
