# Plan Instalacji Homelaba (kreator + skrypty + GitOps)

Dokument uzupełnia „Dokumentację Architektury Rozproszonego Homelaba”. Opisuje kreator generujący paczki instalacyjne, katalog usług, podział: skrypt vs ArgoCD, oraz checklistę kroków instalacji.

## 1. Decyzje

| Temat | Decyzja |
| :--- | :--- |
| Cloudflare | **Nie używamy** na etapie budowy. Może w przyszłości zastąpić VPS-Edge. |
| Systemy serwerów | **Tylko Linux** — pytanie per maszyna, domyślnie **Debian** (Ubuntu jako alternatywa). Instalator dla Windows ewentualnie później. |
| Urządzenia administratora | Kreator generuje konfiguracje dla **Windows, iOS, Android** (WireGuard + certyfikat CA). |
| Backupy | **Poza zakresem** na tym etapie — zakładamy cykliczne backupy po stronie dostawców VPS. |
| Broker | **Redpanda** (wbudowane Schema Registry) — osobny Schema Registry odpada. |
| SonarQube | **Poza homelabem** — lokalny docker-compose na komputerze administratora, uruchamiany na żądanie. |
| Środowisko uruchomieniowe | **k3s lub docker-compose** — per maszyna (domyślna wartość globalna). Instalacja z pakietów odrzucona. Maszyna z aplikacjami z ArgoCD → zawsze k3s. Usługi danych tylko w compose — na maszynie z k3s Docker instalowany obok. Maszyna k3s widzi w wyborze usługi k3s **i** compose; maszyna compose — tylko compose. |
| ArgoCD | Na k3s; narzędzia operacyjne i aplikacje wdrażane przez ArgoCD do klastrów. |
| Rejestracja klastrów w ArgoCD | **Generowana przez kreator** — własne CA każdego klastra k3s + certyfikat klienta `argocd`; Secrety klastrów od razu w paczce ArgoCD. |
| ArgoCD: instalacja i dostęp | Upstream `install.yaml` z przypiętego tagu, **suma SHA-256 sprawdzana** przed `apply` (manifest nie jest kopiowany do repo). Hasło admina: bcrypt `ARGOCD_ROOT_PASSWORD` liczony w kreatorze (`crypt()` libxcrypt). Repo `homelab-gitops` tylko przez **SSH z kluczem deploy read-only** generowanym przez kreator (publiczna część w `INSTALL_ORDER.md`, do dodania ręcznie). Secrety klastrów: każda maszyna z `app-cluster` poza samą maszyną ArgoCD (ta jest `in-cluster`), API `https://<adres WG>:6443`. |
| External Secrets ↔ OpenBao | ESO jako pierwsza aplikacja (chart przypięty), `ClusterSecretStore` → KV `homelab/` w OpenBao po WG. Uwierzytelnianie tokenem: kreator generuje `OPENBAO_ESO`, instalator OpenBao tworzy z tym ID osierocony token tylko do odczytu (polityka `eso-read`). `shortcut:` długi token (10 lat) bez odnawiania — docelowo uwierzytelnianie Kubernetes. |
| Sekrety aplikacji | **OpenBao + External Secrets Operator** — centralny magazyn haseł; w Git tylko odwołania (`ExternalSecret`). OpenBao zamiast Vault ze względu na licencję (Vault: BSL od 2023). |
| Unseal OpenBao | Etap VirtualBox: **automatyczny z pliku na maszynie** (systemd). Produkcja: ręczny lub auto-unseal przez zewnętrzny KMS. |
| Inicjalizacja OpenBao | `bao operator init` **na serwerze**, raz (OpenBao sam generuje klucz główny — kreator nie może go dostarczyć); klucz unseal i root token w `/var/lib/homelab/openbao/init.json` (root, `600`). Instalator inicjalizuje tylko przy jawnym `initialized: false`, a przy niejasnym stanie albo istniejącym `init.json` przy niezainicjalizowanym serwerze — zatrzymuje się. Magazyn `raft` (OpenBao 2.7 nie ma `file` ani mlock — swap wyłączony lub szyfrowany). Wszystkie sekrety kreatora w KV `homelab/<usługa>`. |
| Traefik standalone | Zawsze na edge, nie da się pominąć (w katalogu: `PLACEMENT=edge`). Klastry k3s używają wbudowanego Traefika jako ingressu (na edge z k3s: `--disable traefik`). |
| Aplikacje | Przez ArgoCD, wzorzec **app-of-apps** (repo `homelab-gitops`) — definicje w Git. |
| Repozytoria | **Dwa osobne:** `homelab` (kreator, katalog usług, skrypty instalacyjne — ogólne narzędzie z potencjałem komercyjnym) oraz `homelab-gitops` (konfiguracja konkretnej instancji dla ArgoCD, app-of-apps). Adres repo gitops jest parametrem kreatora; ArgoCD ma klucz read-only wyłącznie do `homelab-gitops`. |
| Domena lokalna | **`homelab.internal`**; certyfikaty z własnego CA (step-ca, endpoint ACME). |
| CA | **Generowane przez kreator** (`step certificate create`) — root + intermediate; intermediate do paczki maszyny ze step-ca, certyfikat główny do wszystkich paczek. |
| Adresacja WG | Edge `10.100.10.100`, kolejne maszyny `.101`–`.199` (inkrementacja); urządzenia administratora `.200`–`.254`. Kreator waliduje wyczerpanie zakresów. Adres DNS w konfiguracjach WG = adres WG maszyny z CoreDNS (wyliczany, nie stały). |
| Kroki systemowe | Kroki 01–04, Docker (10) i k3s (11) są w `common/`, **nie w katalogu usług**. Docker i k3s dokłada logika środowiska maszyny. Katalog zaczyna się od node_exporter (12). |
| Porty publiczne | Tylko usługi z `PLACEMENT=edge` mogą mieć `PUBLIC_PORTS` (bindowane publicznie, np. Traefik 80/443). Wszystkie inne porty (`PORTS`) — wyłącznie na adresie WG. |
| Porty usług | Domyślne porty z katalogu można **przenieść per maszyna i usługa** (`machines[].port_overrides`, w kreatorze `M<n>_PORTS="usługa:port=nowy_port …"`) — przy jednym serwerze wszystkie usługi stoją razem (np. step-ca i RustFS domyślnie na 9000). Zmienia się port po stronie hosta (adres WG), w kontenerze zostaje domyślny; usługi korzystające z przeniesionej (eksportery, Traefik → step-ca) dostają nowy port automatycznie. Nie przenosi się portów z `FIXED_PORTS` (DNS 53, Traefik 80/443 — klienci oczekują ich tam). Konflikt portów kreator zgłasza z podpowiedzią. |
| Port WireGuard | Per maszyna (`wg_port` w stanie). Port podany dla edge (domyślnie `51820`) jest domyślny dla kolejnych maszyn, każdą można zmienić — w homelabie dostępne są wszystkie porty, produkcyjny VPS może udostępniać tylko kilka albo jeden. `Endpoint` peera = jego adres osiągalności + jego `wg_port`. |
| Port SSH | Per maszyna (`ssh_port` w stanie), domyślnie `22`, zmieniany w odpowiedziach kreatora. Używany w `sshd_config` (krok 01) i UFW (krok 03). |
| Priorytety eksporterów | Wszystkie eksportery (`auto`) mają priorytet **39** — po warstwie danych (30–35), przed edge (40). `node-exporter` (`always`) to usługa hosta z priorytetem 12. |
| Znaczniki kroków | Kroki `common/` — `done/NN`; kroki usług — `done/NN-id` (np. `30-postgresql`), więc usługi o tym samym priorytecie się nie zderzają. Wyjątek w `common/`: `03-ssh`. |
| Magazyn obiektów (S3) | **RustFS** (Apache-2.0) zamiast MinIO — repozytorium MinIO zarchiwizowane (ostatnie wydanie 2025-10-15, obraz usunięty z Docker Hub); RustFS jest pomyślany jako zamiennik MinIO. Alarik odrzucony (wersja beta), Garage (AGPL), SeaweedFS (cięższy), Versity Gateway (mniej funkcji). |
| Pamięć podręczna | **Valkey** (BSD-3) zamiast Redis 8 (RSALv2/SSPLv1/AGPLv3) — ten sam protokół i ACL; spójne z wyborem OpenBao zamiast Vault ze względu na licencję. |
| Broker | **Redpanda** zostaje mimo licencji BSL/RCL (kod dostępny, nie open source): używanie we własnym systemie jest dozwolone, ograniczenie dotyczy oferowania go jako usługi streamingowej. Alternatywa przy zmianie: Apache Kafka (KRaft). |
| Konta tylko do odczytu | Jedna nazwa roli: **`VIEWER`** (panele i eksportery, osobne konta per usługa). |
| Język kreatora | **Bash** (`whiptail`, fallback na `read`). |

## 2. Kreator (generator paczek)

Uruchamiany na Linuksie — lokalnie lub bezpośrednio na maszynie. Zbiera odpowiedzi, generuje sekrety, CA i paczki instalacyjne. Stan zapisuje, by można było później dodać maszynę. Wymagane narzędzia: `wg` (wireguard-tools), `step` (step-cli), `openssl`, `qrencode`, opcjonalnie `whiptail` — kreator sprawdza je na starcie i proponuje instalację.

### Przebieg
1. **Liczba maszyn** — 1 (wszystko na edge) lub 2+ (edge + pozostałe).
2. **Urządzenia administratora** — nazwa i typ (Windows / iOS / Android / Linux) → adresy od `.200`, klucze WG.
3. **Iteracja po maszynach, zaczynając od edge.** Dla każdej:
   * nazwa (podpowiedź `edge`, `vps1`…), adres osiągalności (IP VirtualBox / publiczne — `Endpoint` WireGuarda), adres WG nadawany automatycznie,
   * port WireGuarda (podpowiedź: port edge, na edge `51820`) i port SSH (podpowiedź `22`) — oba do zmiany,
   * po wyborze usług: opcjonalne przeniesienie portów (`usługa:port=nowy_port`, domyślnie bez zmian),
   * system (domyślnie Debian),
   * środowisko: k3s / docker-compose (jeśli maszyna ma uruchamiać aplikacje z ArgoCD → wymuszone k3s),
   * lista usług:
     * usługi z `PLACEMENT=edge` (Traefik) — na edge zaznaczone i zablokowane, na pozostałych maszynach ukryte,
     * usługi `single` wybrane na wcześniejszych maszynach są odfiltrowane,
     * maszyna k3s widzi usługi k3s i compose (Docker doinstalowany obok), maszyna compose — tylko compose.
4. **Walidacja** — spójność wyborów (np. ArgoCD bez żadnego k3s, brak step-ca/DNS/OpenBao, niespełnione `REQUIRES`, konflikt portów, wyczerpanie adresów).
5. **Sekrety i certyfikaty** — klucze WireGuard, hasła usług, root CA + intermediate, CA każdego klastra k3s + certyfikat klienta `argocd`, klucz unseal OpenBao.
6. **Generowanie paczek** + kolejność instalacji wyliczona z priorytetów (kolejność wyboru jest tylko prezentacją).

### Konwencja sekretów
Kreator generuje wszystkie hasła centralnie. Prefiks `{USLUGA}` = `ID` usługi wielkimi literami, `-` zamienione na `_` (np. `postgres-exporter` → `POSTGRES_EXPORTER`).
* `{USLUGA}_ROOT_USERNAME` / `{USLUGA}_ROOT_PASSWORD`
* `{USLUGA}_DEFAULT_USERNAME` / `{USLUGA}_DEFAULT_PASSWORD`
* `{USLUGA}_VIEWER_USERNAME` / `{USLUGA}_VIEWER_PASSWORD` — konta tylko do odczytu (panele, eksportery)
* `{USLUGA}_{NAZWA}_USERNAME` / `{USLUGA}_{NAZWA}_PASSWORD` — inne konta dodatkowe

Przepływ:
* **Warstwa compose** (bazy, broker, cache) — hasła z `secrets.env` w paczce maszyny (bazy muszą znać hasło przy starcie, zanim działa OpenBao). Każda maszyna dostaje tylko zmienne swoich usług (edge nie dostaje haseł do baz).
* **Aplikacje z ArgoCD** — instalator OpenBao wgrywa wszystkie sekrety do magazynu; aplikacje pobierają je przez External Secrets Operator. W Git tylko `ExternalSecret` z odwołaniem do klucza.
* Awaria OpenBao nie zatrzymuje działających aplikacji — Secrety skopiowane do klastrów pozostają; wstrzymana jest tylko synchronizacja nowych/zmienionych.

### Dodanie maszyny później
Kreator wczytuje zapisany stan, nadaje kolejny adres WG, generuje klucze i paczkę (dla nowego klastra k3s także CA i Secret do ArgoCD). Ponieważ WireGuard działa w pełnej siatce, nowy peer zmienia `wg0.conf` na wszystkich maszynach — kreator wskazuje, gdzie ponownie uruchomić krok WireGuard.

### Konfiguracje urządzeń administratora
| Urządzenie | WireGuard | Certyfikat główny CA |
| :--- | :--- | :--- |
| Windows | plik `.conf` do importu w kliencie WireGuard | `root_ca.crt` + skrypt `install-ca.ps1` (`Import-Certificate` do Trusted Root) |
| iOS | `.conf` + kod QR (`qrencode`) | profil `.mobileconfig`; po instalacji włączyć pełne zaufanie: Ustawienia → Ogólne → To urządzenie → Ustawienia zaufania certyfikatów |
| Android | `.conf` + kod QR | `root_ca.crt` do instalacji ręcznej (Ustawienia → Bezpieczeństwo → Certyfikat CA); zaufany przez przeglądarkę, nie przez wszystkie aplikacje |
| Linux | `.conf` dla `wg-quick` / NetworkManager | `root_ca.crt` do `/usr/local/share/ca-certificates` + `update-ca-certificates` |

Wszystkie konfiguracje mają `DNS = <adres WG maszyny z DNS wewnętrznym>`. Na telefonach zalecany tryb on-demand.

### Struktura wyniku
```
out/
├── state.yaml          # stan kreatora (inventory)
├── secrets.env         # wszystkie sekrety (chmod 600, poza Git)
├── ca/                 # root_ca.crt, root_ca.key (chmod 600), intermediate
├── k3s-ca/<klaster>/   # CA klastrów k3s + certyfikat klienta argocd
├── common/
│   ├── lib.sh          # funkcje wspólne, logowanie, znaczniki idempotencji
│   ├── 01-base.sh
│   ├── 02-wireguard.sh
│   ├── 03-ufw.sh
│   ├── 04-ca-trust.sh
│   ├── 10-docker.sh
│   ├── 11-k3s.sh
│   └── root_ca.crt
├── edge/
│   ├── install.sh      # kroki z common + własne, we właściwej kolejności
│   ├── node.env        # nazwa, adres WG, wybrane usługi
│   ├── secrets.env     # tylko sekrety tej maszyny
│   ├── wg0.conf
│   └── services/traefik/...
├── vps1/ ...
├── admin-devices/
│   ├── laptop/         # wg .conf, root_ca.crt, install-ca.ps1
│   └── telefon/        # wg .conf, QR .png, .mobileconfig lub .crt
└── INSTALL_ORDER.md
```
Na maszynę trafia `common/` + jej katalog (np. jako `edge.tar.gz`), uruchomienie: `sudo ./install.sh`. Klucz root CA (`ca/root_ca.key`) nie trafia do żadnej paczki — do maszyny ze step-ca trafia tylko intermediate (certyfikat + klucz).

## 3. Katalog usług

Każda usługa to katalog `catalog/<id>/` z plikiem `service.conf` (format `KLUCZ=wartość`, wczytywany przez `source`) oraz szablonami (`docker-compose.yml.tpl`, manifesty k3s, `install.sh`).

Kroki systemowe (01–04), Docker (10) i k3s (11) **nie są w katalogu** — należą do `common/`; Docker i k3s dokłada logika środowiska maszyny. Katalog zaczyna się od node_exporter (12).

```bash
ID=postgresql
NAME="PostgreSQL"
SCOPE=single            # always | single | multi | auto
RUNTIMES="compose"      # compose | k3s
PLACEMENT=""            # edge = tylko i obowiązkowo na edge; puste = dowolna maszyna
PRIORITY=30             # niższy = wcześniej
REQUIRES=""             # usługi, które muszą istnieć w homelabie
SECRETS="ROOT DEFAULT VIEWER"
USES_SECRETS=""         # sekrety innych usług, np. "VALKEY:VIEWER"
PORTS="5432"            # bindowane na adres WG
PUBLIC_PORTS=""         # bindowane publicznie; dozwolone tylko przy PLACEMENT=edge
FIXED_PORTS=""          # porty, których nie można przenieść na maszynie (np. DNS 53)
AUTO_ADD="postgres-exporter"
```

* `always` — na każdej maszynie, nie pokazywane w wyborze.
* `single` — raz w homelabie; po wyborze znika z list kolejnych maszyn.
* `multi` — może być na wielu maszynach.
* `auto` — dodawane automatycznie razem z inną usługą (`AUTO_ADD`), nie pokazywane w wyborze.

| Priorytet | Usługa | Scope | Środowiska | Sekrety | Uwagi |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 12 | node_exporter | always | compose, k3s | — | |
| 20 | DNS wewnętrzny (CoreDNS) | single | compose, k3s | — | wymagany przy 2+ maszynach |
| 21 | step-ca | single | compose, k3s | `STEPCA_DEFAULT` (provisioner) | wymagany; CA z kreatora |
| 30 | PostgreSQL | single | compose | ROOT, DEFAULT, VIEWER | + postgres-exporter (auto, 39, konto VIEWER z `pg_monitor`) |
| 31 | MariaDB | single | compose | ROOT, DEFAULT, VIEWER | + mysqld-exporter (auto, 39) |
| 32 | RustFS (S3) | single | compose | ROOT | metryki natywne; zamiast MinIO (decyzja „Magazyn obiektów”) |
| 33 | Valkey | single | compose | DEFAULT, VIEWER | ACL; + redis-exporter (auto, 39; obsługuje Valkey); zamiast Redis (decyzja „Pamięć podręczna”) |
| 34 | Redpanda | single | compose | ROOT | SASL, `advertise_kafka_addr` = adres WG; Schema Registry wbudowane |
| 35 | Typesense | single | compose | ROOT (API key) | |
| 40 | Traefik standalone | single, `PLACEMENT=edge` | compose | — | ACME → step-ca; `PUBLIC_PORTS="80 443"` |
| 45 | OpenBao | single | compose | ROOT (token), klucz unseal | wymagany przy ArgoCD; instalator wgrywa wszystkie sekrety; auto-unseal z pliku (systemd) |
| 50 | ArgoCD | single | k3s | ROOT (admin) | `REQUIRES=openbao`; + aplikacja główna app-of-apps, Secrety klastrów z kreatora, External Secrets Operator jako pierwsza aplikacja |
| 60 | Klaster aplikacyjny | multi | k3s | — | rejestracja w ArgoCD z kreatora; wymaga ArgoCD |

### Kolejność instalacji
Kolejność maszyn wynika z najniższego priorytetu ich usług: maszyna z DNS/step-ca → dane → OpenBao → ArgoCD → edge → klastry aplikacyjne. WireGuard na każdej maszynie zestawia się z peerami, gdy te się pojawią. Dzięki generowanej rejestracji ArgoCD podłącza klastry, gdy tylko wstaną.

## 4. Sieć: k3s i Docker na jednej maszynie
* Pule adresów bez konfliktów: Docker `172.17.0.0/16`, k3s pody `10.42.0.0/16`, k3s serwisy `10.43.0.0/16`, WireGuard `10.100.10.0/24`.
* Pod → usługa compose na **tej samej** maszynie: ruch przychodzi z puli podów, więc na maszynach z k3s UFW dodatkowo wpuszcza `10.42.0.0/16` na porty usług.
* Pod → usługa na **innej** maszynie: k3s podmienia źródło na adres WG maszyny — wystarczają reguły dla `10.100.10.0/24`.
* Weryfikacja: test połączenia z poda do każdej usługi compose (Docker i k3s modyfikują te same reguły `iptables`).

## 5. Domeny i certyfikaty

### Etap VirtualBox
* Domena **`homelab.internal`**: hosty (`edge.homelab.internal`, `vps1.homelab.internal`…), panele (`argo.`, `grafana.`, `redpanda.`, `s3.` (RustFS), `valkey.`, `bao.homelab.internal`), aplikacje testowe przez edge (np. `e-konkursy.homelab.internal`).
  * `.local` odrzucona — zarezerwowana dla mDNS (RFC 6762).
* DNS wewnętrzny (CoreDNS) serwuje strefę `homelab.internal`.
* CA: root + intermediate generowane przez kreator; **step-ca** podpisuje certyfikaty intermediate i udostępnia endpoint ACME. Traefik używa resolvera ACME z `caServer` wskazującym na step-ca — docelowo zmienia się tylko adres CA.

### Etap produkcyjny (później)
* Edge: Let's Encrypt **HTTP-01**.
* Panele (tylko VPN): do decyzji — DNS-01 przez API dostawcy DNS albo dalej własne CA.

## 6. Podział: skrypt vs ArgoCD

### Skrypt (usługi instalowane bezpośrednio)
* Zawsze: system bazowy, WireGuard, UFW, zaufanie do CA, node_exporter.
* Środowisko: Docker + compose lub k3s.
* Edge: Traefik standalone.
* Infrastruktura: DNS wewnętrzny, step-ca, OpenBao, ArgoCD (+ aplikacja główna app-of-apps, Secrety klastrów).
* Dane: Redpanda, Valkey (ACL), Typesense, PostgreSQL, MariaDB, RustFS + eksportery.
* Wszystkie porty usług bindowane na adres WireGuard.

### ArgoCD (repo `homelab-gitops`)
* Fundament: External Secrets Operator (pierwsza aplikacja, połączenie z OpenBao).
* Narzędzia: kube-prometheus-stack (Prometheus, Grafana, Alertmanager), konsola Redpandy / Kafka-UI (read-only), Valkey-UI, Spring Cloud Config Server.
* Strony i frontend: pionki.online, pionas.dev, excellent-app.pl, aplikacje wspólne, web-app i BFF e-konkursy.
* Mikroserwisy e-konkursy: konkursy, forum, auth, użytkownicy.
* Klaster zapasowy: kopie aplikacji bezstanowych.

## 7. Kroki instalacji (wykonywane przez `install.sh`)

Kroki idempotentne (znacznik `/var/lib/homelab/done/NN` dla `common/`, `done/NN-id` dla usług, flaga `--force`).

**00 – Preflight** — system (Debian/Ubuntu), root, sieć, wczytanie `node.env`
**01 – System bazowy** — update/upgrade, pakiety, chrony, hostname, strefa czasowa, użytkownik admin + klucz SSH, hardening sshd (port `SSH_PORT`), unattended-upgrades, fail2ban, `ip_forward`
**02 – WireGuard** — `wg0.conf`, `wg-quick@wg0`, test peerów
**03 – Firewall (UFW)** — deny incoming, port WG (`WG_PORT`/udp), SSH (`SSH_PORT`/tcp); SSH publiczny → po teście tunelu tylko `10.100.10.0/24`; porty roli (80/443 tylko edge); na maszynach z k3s dodatkowo `10.42.0.0/16`
**04 – Zaufanie do CA** — `root_ca.crt` z paczki
**10 – Docker** / **11 – k3s** (CA z kreatora umieszczone przed pierwszym startem, `--node-ip` / `--advertise-address` na adres WG, manifest RBAC dla użytkownika `argocd`)
**12 – Monitoring hosta** — node_exporter
**20–60 – Usługi wybrane dla maszyny** — w kolejności priorytetów z katalogu
**90 – Weryfikacja** — `wg show`, `nmap` z zewnątrz, certyfikaty, połączenia pod → usługi compose, połączenie ArgoCD → klastry, failover

## 8. SonarQube (poza homelabem)
Lokalny `docker-compose` (SonarQube Community + PostgreSQL, wolumeny). `docker compose up -d` → `mvn verify sonar:sonar -Dsonar.host.url=http://localhost:9000 -Dsonar.token=...` → `docker compose down`. Wymaga `vm.max_map_count=262144` na hoście.

## 9. Otwarte kwestie
- Konsola Redpandy czy Kafka-UI (kafbat) — wymóg read-only.
- Certyfikaty paneli na etapie produkcyjnym.
- Unseal OpenBao na produkcji (ręczny vs zewnętrzny KMS).
