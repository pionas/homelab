#!/usr/bin/env bats
# Tests for wizard.sh, lib/ui.sh, lib/wizard.sh and lib/validate.sh.
# Answers: tests/fixtures/answers/*.txt; catalog: tests/fixtures/catalog-wizard
#   node-agent always | coredns, step-ca single compose,k3s | postgresql (+postgres-exporter), redis,
#   openbao single compose | traefik single edge 80 443 | argocd single k3s REQUIRES=openbao |
#   app-cluster multi k3s REQUIRES=argocd
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  for t in yq wg openssl qrencode step; do type -P "$t" >/dev/null || skip "$t not installed"; done
  ANS="$REPO_ROOT/tests/fixtures/answers"
  CAT="$REPO_ROOT/tests/fixtures/catalog-wizard"
  OUT="$BATS_TEST_TMPDIR/out"
  REPO=git@github.com:pionas/homelab-gitops.git
}

# wizard ANSWERS_FILE [ARG...] — runs wizard.sh with the fixture catalog into $OUT.
wizard() {
  local answers=$1
  shift
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$ANS/$answers" "$@"
}

field() { yq "$1" "$OUT/state.yaml"; }

# --- happy path -------------------------------------------------------------

@test "two machines: state.yaml with machines, ports, devices and services" {
  wizard two-machines.txt --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(field '.gitops_repo')" = "$REPO" ]
  [ "$(field '.machines[] | [.name, .wg_ip, .runtime, .wg_port, .ssh_port] | join(" ")')" = \
    $'edge 10.100.10.100 compose 51820 22\nvps1 10.100.10.101 k3s 443 2222' ]
  [ "$(field '.machines[0].services | join(" ")')" = "node-agent traefik" ]
  [ "$(field '.machines[1].services | join(" ")')" = "node-agent coredns step-ca postgresql openbao argocd" ]
  [ "$(field '.admin_devices[] | .name + ":" + .type + ":" + .wg_ip')" = \
    $'laptop:linux:10.100.10.200\ntelefon:android:10.100.10.201' ]
}

@test "two machines: secrets, WireGuard and CA files are generated" {
  wizard two-machines.txt --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  local f
  for f in secrets.env vps1/secrets.env edge/wg0.conf vps1/wg0.conf admin-devices/telefon/telefon.png \
    ca/root_ca.crt ca/intermediate_ca.key k3s-ca/vps1/argocd.crt; do
    [ -e "$OUT/$f" ]
  done
  [ ! -e "$OUT/k3s-ca/edge" ]
  grep -qx 'ListenPort = 443' "$OUT/vps1/wg0.conf"
  run ! grep -q POSTGRESQL_ "$OUT/edge/secrets.env"
}

@test "one machine: everything on the edge, no CoreDNS needed" {
  wizard one-machine.txt --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(field '.machines | length')" = 1 ]
  [ "$(field '.machines[0].services | join(" ")')" = "node-agent step-ca postgresql traefik" ]
}

@test "the wizard writes only to the output directory" {
  local before
  before=$(git -C "$REPO_ROOT" status --porcelain --ignored)
  wizard two-machines.txt --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO_ROOT" status --porcelain --ignored)" = "$before" ]
}

# --- ports ------------------------------------------------------------------

@test "ports: defaults are 51820 on the edge, the edge port on later machines, ssh 22" {
  sed -e 's/M1_ENDPOINT=192.168.56.10/& M1_WG_PORT=8443/' -e 's/ M2_WG_PORT=443 M2_SSH_PORT=2222//' \
    "$ANS/two-machines.txt" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(field '.machines[] | .wg_port + " " + .ssh_port')" = $'8443 22\n8443 22' ]
}

@test "invalid: WireGuard port out of range" {
  wizard bad-wg-port.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"machine 'vps1': wg_port must be an integer 1-65535, got: '70000'"* ]]
}

@test "invalid: SSH port collides with a service port on the same machine" {
  wizard port-conflict.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"edge: port 443/tcp used by both ssh and traefik"* ]]
}

@test "WireGuard on 443/udp next to Traefik on 443/tcp is not a conflict" {
  sed 's/M1_ENDPOINT=192.168.56.10/& M1_WG_PORT=443/' "$ANS/two-machines.txt" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
}

# --- plan validation --------------------------------------------------------

@test "invalid: step-ca placed nowhere" {
  wizard missing-step-ca.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"plan: step-ca is required but placed on no machine"* ]]
  [ ! -e "$OUT/state.yaml" ]
}

@test "invalid: CoreDNS missing with 2+ machines" {
  wizard missing-coredns.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"plan: coredns is required but placed on no machine"* ]]
}

@test "invalid: ArgoCD without OpenBao (REQUIRES)" {
  wizard missing-openbao.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"plan: argocd requires openbao on some machine"* ]]
}

@test "ArgoCD is not offered on a compose machine" {
  wizard argocd-on-compose.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"M2_SERVICES: 'argocd' is not one of"* ]]
}

@test "M<n>_ARGOCD=yes forces k3s without asking for the runtime" {
  sed 's/M2_ARGOCD=yes/& M2_RUNTIME=compose/' "$ANS/two-machines.txt" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"answers not used by any question (typo?): M2_RUNTIME"* ]]
}

@test "validate_plan reports all errors at once (runtime fit, single twice, placement, ports, requires)" {
  run bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/validate.sh"; catalog_load "'"$CAT"'"
    state_init repo compose
    state_add_machine edge 10.0.0.1 debian compose 51820 6379; state_set_services edge node-agent traefik redis argocd
    state_add_machine vps1 10.0.0.2 debian compose; state_set_services vps1 node-agent traefik redis app-cluster
    validate_plan'
  [ "$status" -eq 1 ]
  [[ $output == *"edge: argocd needs k3s, machine runtime is compose"* ]]
  [[ $output == *"vps1: traefik may run only on the edge"* ]]
  [[ $output == *"plan: redis may be placed only once, found on 2 machines"* ]]
  [[ $output == *"edge: port 6379/tcp used by both ssh and redis"* ]]
  [[ $output == *"plan: argocd requires openbao on some machine"* ]]
  [[ $output == *"plan: step-ca is required"* ]]
  [[ $output == *"plan: coredns is required"* ]]
}

@test "validate_plan: two services with the same port on one machine" {
  run bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/validate.sh"; catalog_load "'"$CAT"'"
    _CATALOG[redis,PORTS]=5432
    state_init repo compose; state_add_machine edge 10.0.0.1 debian compose
    state_set_services edge node-agent traefik step-ca postgresql redis; validate_plan'
  [ "$status" -eq 1 ]
  [[ $output == *"edge: port 5432/tcp used by both postgresql and redis"* ]]
}

@test "invalid: exhausted machine addresses" {
  {
    echo "MACHINES=101"
    echo 'DEVICES="laptop:linux"'
    echo 'M1_NAME=edge M1_ENDPOINT=10.0.0.1 M1_SERVICES="traefik step-ca coredns"'
    for i in $(seq 2 101); do echo "M${i}_ENDPOINT=10.0.1.$i"; done
  } >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"no free WG address in 10.100.10.101-199"* ]]
}

# --- answers file -----------------------------------------------------------

@test "answers: misspelled keys are an error" {
  wizard typo-key.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"answers not used by any question (typo?): M2_WG_PROT"* ]]
}

@test "answers: missing required answer names the key" {
  sed 's/ M2_ENDPOINT=192.168.56.11//' "$ANS/two-machines.txt" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"missing answer M2_ENDPOINT"* ]]
}

@test "answers: device without a type" {
  wizard bad-device.txt --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"DEVICES: expected name:type, got: telefon"* ]]
}

@test "answers: the file is parsed, never executed" {
  printf 'MACHINES=1 $(touch %s/pwned)\nDEVICES="a:linux"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"a.txt:1: expected KEY=value"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "answers: one or many KEY=value per line, quoted values" {
  run bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/ui.sh"
    printf "A=1 B=\"x y\"  # comment\n  C=3\n" >"'"$BATS_TEST_TMPDIR"'/a.txt"
    ui_load_answers "'"$BATS_TEST_TMPDIR"'/a.txt"
    ui_input A a; echo "$UI_ANSWER"; ui_input B b; echo "$UI_ANSWER"; ui_input C c; echo "$UI_ANSWER"
    ui_input D d dflt; echo "$UI_ANSWER"; ui_unused_answers'
  [ "$status" -eq 0 ]
  [ "$output" = $'1\nx y\n3\ndflt' ]
}

# --- arguments, interactive fallback, re-run ----------------------------------

@test "a new state needs --gitops-repo; unknown arguments are rejected" {
  wizard two-machines.txt
  [ "$status" -ne 0 ]
  [[ $output == *"--gitops-repo is required for a new state"* ]]
  run "$REPO_ROOT/wizard.sh" --bogus
  [ "$status" -ne 0 ]
  [[ $output == *"unknown argument: --bogus"* ]]
}

@test "without --answers and without a terminal the wizard falls back to read" {
  # DEFAULT_RUNTIME MACHINES DEVICES, then edge: NAME ENDPOINT WG_PORT SSH_PORT OS ARGOCD RUNTIME SERVICES,
  # then ROUTES (empty line = default: none)
  printf '%s\n' compose 1 laptop:linux edge 203.0.113.10 '' '' debian no compose step-ca '' >"$BATS_TEST_TMPDIR/in"
  run bash -c '"$REPO_ROOT/wizard.sh" --catalog "'"$CAT"'" --out "'"$OUT"'" --gitops-repo x <"'"$BATS_TEST_TMPDIR"'/in"'
  [ "$status" -eq 0 ]
  [ "$(field '.machines[0] | [.name, .wg_port, .ssh_port, (.services | join(","))] | join(" ")')" = \
    "edge 51820 22 node-agent,step-ca,traefik" ]
}

@test "re-run with a state: existing machines and addresses stay, new machine gets the next address" {
  wizard two-machines.txt --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  cp "$OUT/wg/edge.key" "$BATS_TEST_TMPDIR/edge.key"
  cp "$OUT/ca/root_ca.crt" "$BATS_TEST_TMPDIR/root.crt"
  printf 'MACHINES=3\nDEVICES="laptop:linux"\nM3_NAME=vps2 M3_ENDPOINT=192.168.56.12 M3_RUNTIME=k3s M3_SERVICES="app-cluster"\n' \
    >"$BATS_TEST_TMPDIR/add.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/add.txt"
  [ "$status" -eq 0 ]
  [[ $output == *"re-run install step 02 (WireGuard) on: edge vps1"* ]]
  [ "$(field '.machines[] | .name + " " + .wg_ip + " " + .wg_port')" = \
    $'edge 10.100.10.100 51820\nvps1 10.100.10.101 443\nvps2 10.100.10.102 51820' ]
  diff "$BATS_TEST_TMPDIR/edge.key" "$OUT/wg/edge.key"
  diff "$BATS_TEST_TMPDIR/root.crt" "$OUT/ca/root_ca.crt"
  [ -e "$OUT/k3s-ca/vps2/argocd.crt" ]
}

@test "re-run refuses a different --gitops-repo" {
  wizard two-machines.txt --gitops-repo "$REPO"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$ANS/one-machine.txt" --gitops-repo other
  [ "$status" -ne 0 ]
  [[ $output == *"--gitops-repo differs"* ]]
}

@test "validate_plan: machine names reserved for the DNS zone are rejected" {
  run bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/validate.sh"; catalog_load "'"$CAT"'"
    state_init repo compose
    state_add_machine edge 10.0.0.1 debian compose; state_set_services edge node-agent traefik step-ca coredns
    state_add_machine ca 10.0.0.2 debian compose; state_add_machine ns 10.0.0.3 debian compose
    validate_plan'
  [ "$status" -eq 1 ]
  [[ $output == *"machine name ca is reserved for the homelab.internal zone"* ]]
  [[ $output == *"machine name ns is reserved"* ]]
}

# --- routes (Traefik) ----------------------------------------------------------------

@test "routes: ROUTES host:machine[:fallback]; absent means no routes" {
  wizard two-machines.txt --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(field '.routes // [] | length')" = 0 ]
  printf 'ROUTES="app.homelab.internal:vps1:edge shop.example.org:vps1"\n' | cat "$ANS/two-machines.txt" - >"$BATS_TEST_TMPDIR/a.txt"
  rm -rf "$OUT"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(field '.routes[] | .host + ":" + .machine + ":" + (.fallback // "-")')" = \
    $'app.homelab.internal:vps1:edge\nshop.example.org:vps1:-' ]
}

@test "routes: malformed entry and unknown machine are rejected" {
  printf 'ROUTES="app.homelab.internal"\n' | cat "$ANS/two-machines.txt" - >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"ROUTES: expected host:machine[:fallback_machine], got: app.homelab.internal"* ]]
  printf 'ROUTES="app.homelab.internal:vps9"\n' | cat "$ANS/two-machines.txt" - >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"unknown machine 'vps9'"* ]]
}

@test "routes: a host in the zone may not take a machine or panel name" {
  printf 'ROUTES="vps1.homelab.internal:vps1 argo.homelab.internal:vps1"\n' | cat "$ANS/two-machines.txt" - >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --catalog "$CAT" --out "$OUT" --answers "$BATS_TEST_TMPDIR/a.txt" --gitops-repo "$REPO"
  [ "$status" -ne 0 ]
  [[ $output == *"route host vps1.homelab.internal clashes with a machine or panel name"* ]]
  [[ $output == *"route host argo.homelab.internal clashes"* ]]
}
