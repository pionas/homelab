# homelab — kreator i skrypty instalacyjne
 
Rozproszony homelab (multi-VPS / multi-cloud). To repozytorium zawiera **kreator** generujący paczki instalacyjne dla maszyn oraz **katalog usług** ze skryptami i szablonami. Konfiguracja aplikacji dla ArgoCD jest w osobnym repo `homelab-gitops` (adres repo to parametr kreatora).
 
Pełna architektura i decyzje: `docs/architektura.md`, `docs/plan-instalacji.md`. **Przed zmianą założeń przeczytaj te dokumenty; decyzje z tabeli w planie instalacji traktuj jako ustalone.**
 
## Etap prac
 
Piszemy kod i testujemy go **fragmentami** na laptopie (Debian). Pełne środowisko (VirtualBox / VPS) stawiamy dopiero, gdy kod będzie kompletny.
 
## Struktura
 
```
wizard.sh              # punkt wejścia kreatora
lib/                   # funkcje kreatora (ui, state, secrets, wg, ca, catalog, render)
catalog/<id>/          # service.conf + szablony (*.tpl, manifesty k3s, install.sh)
common/                # kroki instalacji wspólne: lib.sh, 01-base.sh, 02-wireguard.sh ...
scripts/dev.sh         # komendy deweloperskie (lint, test, golden, validate, container)
tests/unit/            # testy bats funkcji kreatora
tests/golden/          # oczekiwane wyniki generowania dla przykładowych state.yaml
tests/container/       # testy kroków instalacji w kontenerze z systemd
docs/
out/                   # wynik kreatora — NIGDY w Git
```
 
## Konwencje Bash
 
- Każdy skrypt: `#!/usr/bin/env bash` + `set -Eeuo pipefail`.
- Kod musi przechodzić `shellcheck` bez ostrzeżeń i być sformatowany `shfmt -i 2 -ci`.
- Logika w funkcjach w `lib/`; `wizard.sh` tylko je składa. Funkcje mają być testowalne bez roota i bez interakcji (UI `whiptail` / `read` oddzielone od logiki).
- Kroki instalacji są idempotentne: znacznik `/var/lib/homelab/done/NN`, flaga `--force`.
- Komendy zmieniające system wywołuj przez wrapper `run` z `common/lib.sh`, który obsługuje `--dry-run` (wypisuje komendę zamiast ją wykonać).
- Porty usług zawsze bindowane na adres WireGuard, nigdy na `0.0.0.0`.
- Sekrety: konwencja `{USLUGA}_ROOT_*`, `{USLUGA}_DEFAULT_*`, `{USLUGA}_VIEWER_*`. Żadnych sekretów, kluczy ani `out/` w Git.
## Testowanie — zasady bezpieczeństwa
 
- **Nigdy nie uruchamiaj kroków instalacji (`install.sh`, `common/0*.sh`, `1*.sh`) bezpośrednio na laptopie.** Zmieniają UFW, WireGuard, sshd, użytkowników i mogą odciąć dostęp do maszyny. Uruchamiaj je tylko z `--dry-run` albo w kontenerze z `tests/container/`.
- Kreator (`wizard.sh`) można uruchamiać lokalnie — pisze wyłącznie do `out/` (lub katalogu z `--out`).
## Komendy
 
```bash
scripts/dev.sh lint        # shellcheck + shfmt -d -i 2 -ci (także service.conf)
scripts/dev.sh test        # bats tests/unit
scripts/dev.sh golden      # generowanie z tests/golden/*/state.yaml i porównanie z oczekiwanym wynikiem
scripts/dev.sh validate    # walidacja wygenerowanych plików: docker compose config, kubeconform, yq
scripts/dev.sh container   # testy kroków instalacji w kontenerze Debian z systemd
scripts/dev.sh lint test   # kilka komend naraz; bez make — zwykły skrypt Bash
```
 
## Weryfikacja wygenerowanych plików
 
- `docker-compose.yml` → `docker compose -f ... config -q`
- manifesty k3s → `kubeconform -strict`
- YAML (Traefik, state.yaml) → `yq` (mikefarah/yq, nie pakiet Debiana o tej samej nazwie)
- certyfikaty → `step certificate verify` / `openssl verify`
- `wg0.conf` → spójność kluczy publicznych i adresów między peerami (test bats)

## Praca autonomiczna (agent-runner)
- Zadanie: `.agent/TASK.md`. Stan: `.agent/PROGRESS.md` (pierwsza linia `STATUS: ...`).
- Nie rób push/PR/rebase — robi to runner.
- Wątpliwości, które blokują sensowną pracę → `STATUS: NEEDS_INPUT` + konkretne pytania w formacie `Q-01` z wariantami `A`/`B` (reguła `ai/rules/common/questions.md` platformy).

## Konflikt z gałęzią główną (`main`)
- Nie pytaj właściciela o zgodę: `git fetch origin main && git merge origin/main` (merge, nie rebase), rozwiąż konflikty, uruchom testy, zacommituj merge.
- Pliki generowane (w tym generowana konfiguracja) i blokady zależności przyjmują stan z `main`; kod i ręcznie edytowana konfiguracja zachowują intencję obu stron, potwierdzoną testami.
- Push i PR wykonuje runner; poza runnerem nie pushuj bez zgody zadania lub użytkownika.
- Konflikt nierozwiązywalny albo czerwone testy → `STATUS: BLOCKED` z dowodami (pliki, test), nie pytanie o pozwolenie.
