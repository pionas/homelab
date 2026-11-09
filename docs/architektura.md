# Dokumentacja Architektury Rozproszonego Homelaba (Multi-Cloud / Multi-VPS)

## 1. Wstęp i Założenia Projektu
Projekt zakłada stworzenie elastycznego, rozproszonego środowiska typu homelab, które początkowo uruchamiane jest lokalnie na maszynach wirtualnych (VirtualBox), a docelowo zostanie przeniesione do różnych dostawców chmurowych i serwerowni (np. Hetzner, Hostinger, Mikrus, AWS, GCP, Azure).

Instalacja odbywa się przez kreator generujący paczki instalacyjne dla każdej maszyny — szczegóły w dokumencie **„Plan Instalacji Homelaba”**.

Główne cele:
* **Odporność na awarie bezstanowe:** Awaria pojedynczego VPS-a nie powinna położyć całego systemu. Aplikacje bezstanowe mogą zostać przełączone na zapasowe zasoby w chmurze (AWS / GCP / Azure).
* **Świadoma niedostępność warstwy stanowej:** Awaria bazy danych, Redpandy lub Valkey oznacza akceptowaną niedostępność zależnych usług (brak replikacji multi-region dla danych). Backupy danych po stronie dostawców VPS (poza zakresem projektu na tym etapie).
* **Bezpieczeństwo sieciowe:** Ruch między serwerami jest w pełni szyfrowany i zamknięty w prywatnej sieci VPN (WireGuard).
* **Zarządzanie typu GitOps:** Wdrożenia i synchronizacja stanu oparte na ArgoCD; sekrety w centralnym magazynie (OpenBao), nie w Git.
* **Niezależność od zewnętrznych usług:** Całość budowana bez Cloudflare; Cloudflare może w przyszłości zastąpić VPS-Edge.
* **Potencjał komercyjny:** Wybór Traefik (automatyczne certyfikaty), WireGuard i OpenBao (licencja open source, w przeciwieństwie do Vault na BSL) pod kątem możliwego komercyjnego wykorzystania rozwiązania.

---

## 2. Topologia Infrastruktury i Przydział Komponentów

Środowisko zostało podzielone na wyspecjalizowane warstwy. Tabela opisuje **docelowy podział referencyjny** — kreator pozwala przypisać usługi do dowolnej liczby maszyn (od jednej — wszystko na edge — do pełnego podziału).

| Komponent / VPS | Rola w architekturze | Technologia / Narzędzia |
| :--- | :--- | :--- |
| **VPS-Edge (Bramka)** | Jedyny publiczny punkt wejścia, terminacja TLS, routing do klastrów po WireGuard, failover aplikacji bezstanowych. | Traefik (standalone, Docker, file provider), WireGuard |
| **VPS1 (Hub Operacyjny)** | Infrastruktura i narzędzia operacyjne. **Panele dostępne wyłącznie z sieci VPN.** | **k3s** + Docker. Instalowane skryptem: DNS wewnętrzny (CoreDNS), step-ca, OpenBao (compose), ArgoCD. Wdrażane przez ArgoCD: External Secrets Operator, Prometheus, Grafana, Alertmanager, konsola Redpandy / Kafka-UI, Valkey-UI, Spring Cloud Config Server |
| **VPS2 (Frontend i BFF)** | Strony: pionki.online, pionas.dev, excellent-app.pl; aplikacje wspólne (zarządzanie plikami, monitoring notyfikacji SMS/e-mail/push); e-konkursy.info web-app oraz BFF dla Android/iOS. | **k3s** (niezależny klaster, aplikacje bezstanowe z ArgoCD) |
| **VPS3 (Warstwa Danych In-Memory & Stream)** | Broker wiadomości (z wbudowanym Schema Registry), wyszukiwarka, pamięć podręczna. | Redpanda, Typesense, Valkey (Docker Compose) |
| **VPS4 (Mikroserwisy)** | Logika biznesowa `e-konkursy.info`: konkursy, forum, auth (autoryzacja i autentykacja), użytkownicy. | **k3s** (niezależny klaster, mikroserwisy bezstanowe z ArgoCD) |
| **VPS5 (Trwały Storage & Bazy)** | Magazyn plików oraz relacyjne bazy danych. | RustFS (S3), PostgreSQL, MariaDB (Docker Compose, persistent storage) |
| **Zapasowy klaster chmurowy** | Rezerwa dla aplikacji bezstanowych z VPS2 / VPS4 na wypadek awarii. | k3s w AWS / GCP / Azure, zarządzany przez ArgoCD |
| **Urządzenia administratora** | Laptop / telefon (Windows, iOS, Android, Linux) jako peery WireGuard — dostęp do paneli i narzędzi CLI. | Klient WireGuard (tryb on-demand na telefonie), certyfikat główny CA |

Na każdej maszynie dodatkowo: system bazowy (Debian domyślnie), WireGuard, UFW, zaufanie do CA, node_exporter; przy bazach — eksportery Prometheus.

**Poza homelabem:** SonarQube — lokalny docker-compose na komputerze administratora, uruchamiany na żądanie (nie blokuje CI/CD).

---

## 3. Sieć i Bezpieczeństwo

### 3.1 WireGuard
* Wszystkie maszyny spięte w prywatną podsieć `10.100.10.0/24` ze stałymi adresami nadawanymi przez kreator.
* Cały ruch międzyserwerowy (mikroserwisy → bazy, Redpanda, Valkey; edge → klastry) odbywa się wyłącznie wewnątrz tunelu.
* Topologia: **pełna siatka (mesh)** zamiast hub-and-spoke — hub byłby pojedynczym punktem awarii. Klucze generuje kreator; dodanie maszyny wymaga ponownego wdrożenia `wg0.conf` na pozostałych. Przy większej skali lub zastosowaniu komercyjnym: rozważyć Headscale / NetBird.

Adresacja:

| Adres | Węzeł |
| :--- | :--- |
| 10.100.10.100 | VPS-Edge (zawsze) |
| 10.100.10.101–199 | Kolejne maszyny w kolejności dodawania (w podziale referencyjnym: VPS1 = .101, VPS2 = .102, VPS3 = .103, VPS4 = .104, VPS5 = .105, zapasowe klastry = kolejne) |
| 10.100.10.200–254 | Urządzenia administratora (laptop, telefon) |

Kreator waliduje wyczerpanie zakresów.

### 3.2 Firewall (UFW)
* **VPS-Edge:** jedyna maszyna wystawiona na świat (porty 80/443 oraz port WireGuarda — konfigurowalny per maszyna).
* **Pozostałe maszyny:** publicznie otwarty wyłącznie port WireGuarda. Bazy, Redpanda, Valkey i panele dostępne tylko z `10.100.10.0/24`.
* **SSH:** po zestawieniu tunelu dostępny tylko z `10.100.10.0/24`.
* **Docker + UFW:** Docker przy publikowaniu portów dodaje własne reguły iptables z pominięciem UFW — porty publikowane z bindowaniem na adres WireGuard, np. `"10.100.10.105:5432:5432"`. Weryfikacja z zewnątrz: `nmap`.
* **k3s + Docker na jednej maszynie:** pule bez konfliktów (Docker `172.17.0.0/16`, pody `10.42.0.0/16`, serwisy `10.43.0.0/16`, WG `10.100.10.0/24`). Pody łączą się z usługą compose na tej samej maszynie z puli `10.42.0.0/16` — UFW wpuszcza ją na porty usług. Ruch do innych maszyn wychodzi z adresem WG maszyny.

### 3.3 Dostęp do paneli administracyjnych (decyzja)
**Panele UI (ArgoCD, Grafana, konsola Redpandy / Kafka-UI, Valkey-UI, OpenBao) są dostępne wyłącznie po podłączeniu do sieci VPN — nie są wystawiane przez publiczny VPS-Edge.**

* **Domeny (etap VirtualBox):** strefa `homelab.internal` — `argo.homelab.internal`, `grafana.homelab.internal`, `redpanda.homelab.internal`, `valkey.homelab.internal`, `bao.homelab.internal`; hosty `edge.homelab.internal`, `vps1.homelab.internal`… (`.local` odrzucona — zarezerwowana dla mDNS). Docelowo możliwe przejście na subdomeny `pionas.dev`.
* **DNS:** CoreDNS serwuje strefę `homelab.internal`; konfiguracje WireGuard mają `DNS` = adres WG maszyny z CoreDNS, wyliczany przez kreator (w podziale referencyjnym VPS1 = `10.100.10.101`).
* **TLS:** własne CA — root + intermediate generowane przez kreator; **step-ca** na VPS1 udostępnia endpoint ACME, z którego korzysta Traefik (wbudowany w k3s). Certyfikat główny instalowany na serwerach i urządzeniach administratora.
* **Firewall VPS1:** porty 80/443 tylko dla `10.100.10.0/24`.
* **Tryb read-only podglądu:**
  * Konsola Redpandy / Kafka-UI: tryb tylko do odczytu (brak usuwania topiców / resetu offsetów) — wybór narzędzia otwarty.
  * Valkey: osobny użytkownik ACL `viewer`, np. `ACL SETUSER viewer on >haslo ~* +@read +info +monitor -@dangerous`.
  * Konta tylko do odczytu we wszystkich usługach w roli `VIEWER` (także dla eksporterów).
* **Dostęp CLI z VPN:** `rpk -X brokers=10.100.10.103:9092 ...` lub `kcat -b 10.100.10.103:9092 ...`, `valkey-cli -h 10.100.10.103 --user viewer ...`.
* **Redpanda:** `advertise_kafka_addr` musi ogłaszać adres WireGuard (`10.100.10.103:9092`), inaczej klienci spoza hosta brokera nie połączą się po bootstrapie.
* Wyjątek na przyszłość (dostęp bez VPN): wyłącznie przez edge z forward-auth (Authentik / oauth2-proxy + 2FA), nadal read-only.

### 3.4 Sekrety
* Wszystkie hasła generuje kreator (konwencja `{USLUGA}_ROOT_*`, `{USLUGA}_DEFAULT_*`, `{USLUGA}_VIEWER_*`).
* **Warstwa compose** (bazy, Redpanda, Valkey) — hasła z pliku `secrets.env` w paczce maszyny; każda maszyna dostaje tylko sekrety swoich usług.
* **Aplikacje z ArgoCD** — centralny magazyn **OpenBao** + **External Secrets Operator**; w Git tylko odwołania (`ExternalSecret`). Awaria OpenBao nie zatrzymuje działających aplikacji.
* Unseal OpenBao: etap VirtualBox — automatyczny z pliku (systemd); produkcja — ręczny lub zewnętrzny KMS.

---

## 4. Architektura Wdrożeniowa: Dlaczego Scenariusz B (A Odrzucony)?

* **Scenariusz A (Odrzucony) – Jeden klaster K3s rozciągnięty na wszystkie VPS:**
  * Control plane wymaga niskich opóźnień; różnice między serwerowniami (AWS, GCP, Hetzner, Mikrus) grożą utratą kworum, *split-brain* i niestabilnością. Pojedynczy master staje się punktem awarii dla wszystkich węzłów.
* **Scenariusz B (Wybrany) – Niezależne instancje K3s + Centralny GitOps (ArgoCD):**
  * Pełna izolacja awarii. ArgoCD na VPS1 zarządza wieloma klastrami — VPS2, VPS4 i zapasowym klastrem chmurowym.
  * Rejestracja klastrów deklaratywna: kreator generuje CA każdego klastra k3s (umieszczane przed pierwszym startem) i certyfikat klienta `argocd`; Secrety klastrów trafiają od razu do paczki ArgoCD.
  * Awaria VPS1 blokuje tylko nowe wdrażania, monitoring i synchronizację sekretów — działające aplikacje pracują dalej.

---

## 5. Wybór Technologii Wdrożenia (K3s vs Docker Compose)

Instalacja z pakietów systemowych **odrzucona** — każda usługa działa w k3s lub docker-compose.

### A. Warstwa Aplikacyjna i Mikroserwisy (VPS1, VPS2, VPS4, klaster zapasowy)
* **Wybór:** **K3s (Kubernetes)** — niezależny klaster na każdym VPS. Maszyna uruchamiająca aplikacje z ArgoCD zawsze ma k3s.
* **Uzasadnienie:** automatyczny restart, skalowanie, zmienne środowiskowe, routing; deklaratywny model spójny z ArgoCD.

### B. Warstwa Danych i Bazy Danych (VPS3, VPS5)
* **Wybór:** **Docker Compose** — proste pliki, łatwe backupy, niezależność od klastra.
* K3s / StatefulSets odrzucone: narzut Kubernetes i trudne Persistent Volumes w multi-cloud.
* Jeśli usługa compose trafia na maszynę z k3s (np. OpenBao na VPS1), Docker instalowany jest obok k3s (oba środowiska współistnieją). Maszyna k3s może więc mieć usługi k3s i compose; maszyna compose — tylko compose.

Rozproszony storage blokowy (np. Longhorn) między serwerowniami **nie jest stosowany** — replikacja przez WAN przy opóźnieniach 20–50 ms jest niestabilna.

---

## 6. Ruch Publiczny i Failover (VPS-Edge)

```
Internet → VPS-Edge (Traefik standalone, TLS)
              │  WireGuard (HTTP wewnątrz tunelu)
              ├─→ VPS2 k3s (wbudowany Traefik jako ingress wewnętrzny) → strony, BFF
              │       └─ fallback: zapasowy k3s w AWS / GCP / Azure
              └─→ VPS4 k3s → mikroserwisy (jeśli API publiczne)
```

* Edge jest niezależny od wszystkich backendów — dzięki temu może przełączyć ruch, gdy VPS2/VPS4 padnie.
* Routing przez file provider; failover natywnym typem usługi Traefik:

```yaml
http:
  routers:
    konkursy:
      rule: "Host(`e-konkursy.info`)"
      service: konkursy
      tls: { certResolver: acme }
  services:
    konkursy:
      failover:
        service: konkursy-main
        fallback: konkursy-cloud
    konkursy-main:
      loadBalancer:
        healthCheck: { path: /healthz, interval: 10s }   # wymagany przy failover
        servers: [{ url: "http://10.100.10.102" }]
    konkursy-cloud:
      loadBalancer:
        servers: [{ url: "http://10.100.10.106" }]
```

* **Certyfikaty:**
  * Etap VirtualBox: resolver ACME z `caServer` wskazującym na step-ca (domeny `*.homelab.internal`).
  * Produkcja: Let's Encrypt **HTTP-01** — przy jednym edge wyzwanie zawsze trafia na tę samą maszynę. Zmiana sprowadza się do adresu CA w resolverze.
* Docelowo edge sam jest pojedynczym punktem awarii → dwa edge u różnych dostawców + DNS z health checkiem lub Cloudflare (wtedy certyfikaty przez DNS-01).

---

## 7. Plan Wdrożenia

Kroki instalacji, kreator, katalog usług i kolejność instalacji opisuje dokument **„Plan Instalacji Homelaba”**. W skrócie:

1. **Kreator** (Bash, uruchamiany na Linuksie): maszyny, urządzenia administratora, środowiska, przydział usług → klucze WireGuard, hasła, CA, CA klastrów k3s → paczki instalacyjne + kolejność instalacji.
2. **Instalacja na maszynach** w kolejności wyliczonej z priorytetów: DNS/step-ca → dane → OpenBao → ArgoCD → edge → klastry aplikacyjne.
3. **ArgoCD** (app-of-apps, repo `homelab-gitops`): External Secrets Operator → narzędzia operacyjne → aplikacje.
4. **Odporność:** zapasowy klaster k3s w chmurze, health checki i failover na edge, test awarii VPS2/VPS4.

---

## 8. Alternatywy do Rozważenia w Przyszłości

1. **Cloudflare / Cloudflare Tunnels:** zastąpienie VPS-Edge, gdy całość będzie działać — ochrona DDoS, WAF, ukrycie adresów IP serwerów.
2. **Globalny failover:** external DNS lub Cloudflare Load Balancing kierujący ruch na zapasowy edge/klaster.
3. **Automatyzacja sieci VPN:** Headscale / NetBird przy skalowaniu lub wdrożeniu komercyjnym.
4. **Instalator dla Windows** (serwery) — obecnie tylko Linux.
5. **Backupy warstwy stanowej** po stronie projektu (obecnie po stronie dostawców VPS).
