# Weryfikacja maszyny

## Automatycznie: krok 90

`install.sh` kończy się krokiem `common/90-verify.sh`. Można go uruchomić w dowolnej chwili
(tylko odczyty, bez znacznika):

```bash
sudo ./install.sh --step 90
```

Sprawdza: `wg0` na `WG_PORT`, sshd na `SSH_PORT`, aktywny UFW, zaufanie do root CA, na k3s — API,
CA z kreatora i połączenie z poda do każdego portu usług na adresie WG, node_exporter na
`<adres WG>:9100`. Każdy problem jest wypisany, na końcu kod 1.

## Ręcznie: skan z zewnątrz (`nmap`)

Krok 90 nie widzi maszyny z internetu. Na VM / VPS uruchom skan **z innej maszyny, spoza sieci
WireGuard** (np. z laptopa bez włączonego tunelu), podając publiczny adres badanej maszyny:

```bash
# TCP: wszystkie porty
nmap -Pn -p- <publiczne IP>
# UDP: port WireGuard (domyślnie 51820, albo WG_PORT z node.env)
sudo nmap -Pn -sU -p <WG_PORT> <publiczne IP>
```

Oczekiwany wynik:

| Maszyna | Otwarte z zewnątrz | Wszystko inne |
| :--- | :--- | :--- |
| edge | `80/tcp`, `443/tcp`, `<WG_PORT>/udp` (`open\|filtered`) | `filtered` |
| pozostałe | `<WG_PORT>/udp` | `filtered` |
| przed krokiem 03-ssh | dodatkowo `<SSH_PORT>/tcp` | |

Każdy inny otwarty port (np. `5432`, `9100`, `6443`, `8200`) to błąd: usługa nie jest
zbindowana na adres WG albo reguła UFW jest za szeroka. Te same porty **z** sieci WireGuard
(`nmap -Pn <adres WG>` z urządzenia admina) mają być osiągalne.

## Testy w kontenerze

`scripts/dev.sh container` uruchamia kroki naprawdę w kontenerze Debian z systemd
(`tests/container/`), trzy razy: instalacja, drugie uruchomienie (wszystkie kroki pominięte),
`--force`. Czego nie da się zrobić w kontenerze (hostname, sysctl, start dockerd i k3s), jest
pomijane z komunikatem `skipped in container: …` — to sprawdza się dopiero na VM.
