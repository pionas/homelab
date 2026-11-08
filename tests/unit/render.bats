#!/usr/bin/env bats
# Tests for lib/render.sh through wizard.sh on tests/golden/reference/answers.txt
# (catalog tests/fixtures/catalog-wizard):
#   edge: traefik | vps1 (k3s): coredns step-ca openbao argocd | vps2 (compose, wg 443, ssh 2222):
#   postgresql redis | vps3, vps4 (k3s): app-cluster | vps5: nothing extra
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup_file() {
  for t in yq wg openssl qrencode step; do type -P "$t" >/dev/null || skip "$t not installed"; done
  export OUT="$BATS_FILE_TMPDIR/out" CAT="$BATS_TEST_DIRNAME/../fixtures/catalog-wizard"
  "$BATS_TEST_DIRNAME/../../wizard.sh" --catalog "$CAT" --out "$OUT" --gitops-repo git@example.com:g.git \
    --answers "$BATS_TEST_DIRNAME/../golden/reference/answers.txt" >/dev/null 2>&1
}

setup() {
  load helpers
  [ -e "$OUT/state.yaml" ] || skip "wizard did not run"
}

listing() { tar -tzf "$OUT/$1.tar.gz"; }

@test "packages: common/ + the machine's directory only" {
  run listing vps2
  [ "$status" -eq 0 ]
  for f in "${lines[@]}"; do [[ $f == common/* || $f == vps2/* ]]; done
  [[ $output == *"common/lib.sh"* && $output == *"common/root_ca.crt"* ]]
  for f in install.sh node.env secrets.env wg0.conf services/postgresql/docker-compose.yml; do
    [[ $output == *"vps2/$f"* ]]
  done
}

@test "security: no package has the root CA key, all secrets or private WireGuard keys" {
  local m
  for m in edge vps1 vps2 vps3 vps4 vps5; do
    run listing "$m"
    [[ $output != *root_ca.key* ]]
    [[ $output != *"wg/"* ]]
    # Only the machine's own secrets.env, never OUT/secrets.env with every service's passwords.
    [ "$(listing "$m" | grep secrets.env)" = "$m/secrets.env" ]
    [ "$(listing "$m" | grep wg0.conf)" = "$m/wg0.conf" ]
  done
}

@test "security: intermediate CA only in the package of the step-ca machine" {
  [[ $(listing vps1) == *"vps1/ca/intermediate_ca.key"* ]]
  local m
  for m in edge vps2 vps3 vps4 vps5; do [[ $(listing "$m") != *intermediate_ca* ]]; done
}

@test "security: edge gets no database passwords" {
  run ! grep -E '^(POSTGRESQL|REDIS)_' "$OUT/edge/secrets.env"
  grep -q '^POSTGRESQL_ROOT_PASSWORD=' "$OUT/vps2/secrets.env"
}

@test "k3s: each cluster's CA set only in its own package; ArgoCD gets server CA and argocd cert, not CA keys" {
  [[ $(listing vps3) == *"vps3/k3s-ca/vps3/client-ca.key"* ]]
  [[ $(listing vps3) != *"k3s-ca/vps4"* ]]
  run listing vps1
  [[ $output == *"vps1/k3s-ca/vps3/server-ca.crt"* && $output == *"vps1/k3s-ca/vps3/argocd.key"* ]]
  [[ $output != *"vps1/k3s-ca/vps3/client-ca.key"* && $output != *"vps1/k3s-ca/vps3/server-ca.key"* ]]
  [[ $(listing vps2) != *k3s-ca* ]]
}

@test "node.env: WG_PORT and SSH_PORT from the state, also non-default ones" {
  grep -qx 'WG_PORT=443' "$OUT/vps2/node.env"
  grep -qx 'SSH_PORT=2222' "$OUT/vps2/node.env"
  grep -qx 'WG_PORT=51820' "$OUT/vps1/node.env"
  grep -qx 'SSH_PORT=22' "$OUT/vps1/node.env"
  grep -qx 'SERVICES="node-agent postgresql redis postgres-exporter"' "$OUT/vps2/node.env"
}

@test "install.sh: common steps, Docker only with compose services, k3s on k3s, services by priority" {
  run grep -E '^  (\.\./common|services)/' "$OUT/vps2/install.sh"
  [ "$output" = "  ../common/00-preflight.sh
  ../common/01-base.sh
  ../common/02-wireguard.sh
  ../common/03-ufw.sh
  ../common/04-ca-trust.sh
  ../common/10-docker.sh
  services/node-agent/install.sh
  services/postgresql/install.sh
  services/redis/install.sh
  services/postgres-exporter/install.sh" ]
  run grep -c -e 10-docker -e 11-k3s "$OUT/vps3/install.sh"
  [ "$output" = 1 ] # k3s only: app-cluster runs in k3s, node-agent too
  grep -q 11-k3s "$OUT/vps3/install.sh"
  grep -q 10-docker "$OUT/vps1/install.sh" # openbao is compose-only
  [ "$(stat -c %a "$OUT/vps2/install.sh")" = 700 ]
  bash -n "$OUT/vps2/install.sh"
}

@test "templates: only node.env and the machine's secrets are substituted; output mode 600" {
  local f="$OUT/vps2/services/postgresql/docker-compose.yml"
  grep -qF '"10.100.10.102:5432:5432"' "$f"
  grep -qF 'PGDATA: ${PGDATA:-/var/lib/postgresql/data}' "$f"
  grep -qx "      POSTGRES_PASSWORD: $(sed -n 's/^POSTGRESQL_ROOT_PASSWORD=//p' "$OUT/vps2/secrets.env")" "$f"
  [ "$(stat -c %a "$f")" = 600 ]
  [ ! -e "$OUT/vps2/services/postgresql/service.conf" ]
}

@test "admin devices get the root CA certificate" {
  for d in laptop telefon tablet pc; do cmp "$OUT/ca/root_ca.crt" "$OUT/admin-devices/$d/root_ca.crt"; done
}

@test "re-rendering removes services no longer on the machine and gives identical archives" {
  cp "$OUT/vps1.tar.gz" "$BATS_TEST_TMPDIR/vps1.tar.gz"
  run bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/render.sh"; catalog_load "$CAT"
    state_load "$OUT/state.yaml"; render_all "$OUT"
    state_set_services vps2 node-agent redis; render_all "$OUT"'
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/vps1.tar.gz" "$OUT/vps1.tar.gz"
  [ ! -e "$OUT/vps2/services/postgresql" ]
  [[ $(listing vps2) != *postgresql* ]]
}
