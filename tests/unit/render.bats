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
  services/postgres-exporter/install.sh
  ../common/90-verify.sh" ]
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
  local copy="$BATS_TEST_TMPDIR/out"
  cp -a "$OUT" "$copy"
  run env OUT="$copy" bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/render.sh"; catalog_load "$CAT"
    state_load "$OUT/state.yaml"; render_all "$OUT"
    state_set_services vps2 node-agent redis; render_all "$OUT"'
  [ "$status" -eq 0 ]
  cmp "$OUT/vps1.tar.gz" "$copy/vps1.tar.gz"
  [ ! -e "$copy/vps2/services/postgresql" ]
  [[ $(tar -tzf "$copy/vps2.tar.gz") != *postgresql* ]]
}

@test "install.sh --step runs one step (03-ssh -> 03-ufw.sh, NN-id -> service), passes flags, rejects unknown" {
  local pkg="$BATS_TEST_TMPDIR/pkg" f
  mkdir -p "$pkg" && tar -xzf "$OUT/vps2.tar.gz" -C "$pkg"
  # Stub steps that only print their name and arguments: nothing real runs here.
  for f in 00-preflight 01-base 02-wireguard 03-ufw 04-ca-trust 10-docker 90-verify; do
    printf 'echo "%s $*"\n' "$f" >"$pkg/common/$f.sh"
  done
  for f in node-agent postgresql redis postgres-exporter; do
    mkdir -p "$pkg/vps2/services/$f" && printf 'echo "%s $*"\n' "$f" >"$pkg/vps2/services/$f/install.sh"
  done
  run "$pkg/vps2/install.sh" --step 03-ssh --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "03-ufw --dry-run" ]
  run "$pkg/vps2/install.sh" --step 30-postgresql
  [ "$output" = "postgresql " ]
  run "$pkg/vps2/install.sh" --force
  [ "${#lines[@]}" -eq 11 ]
  [ "${lines[0]}" = "00-preflight --force" ]
  [ "${lines[9]}" = "postgres-exporter --force" ]
  [ "${lines[10]}" = "90-verify --force" ]
  run "$pkg/vps2/install.sh" --step 90
  [ "$output" = "90-verify " ]
  run "$pkg/vps2/install.sh" --step 99
  [ "$status" -eq 2 ]
  [[ $output == *"unknown step: 99"* ]]
  rm "$pkg/common/02-wireguard.sh"
  run "$pkg/vps2/install.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"missing install step: ../common/02-wireguard.sh"* ]]
  [[ $output != *00-preflight* ]] # nothing runs when a step file is missing
}

@test "node.env: service PORTS (WireGuard only) and PUBLIC_PORTS (edge)" {
  grep -qx 'PORTS="5432 6379 9100 9187"' "$OUT/vps2/node.env"
  grep -qx 'PUBLIC_PORTS=""' "$OUT/vps2/node.env"
  grep -qx 'PUBLIC_PORTS="80 443"' "$OUT/edge/node.env"
}

@test "security: install.sh accepts only --dry-run, --force and one --step from its own list" {
  local pkg="$BATS_TEST_TMPDIR/pkg" f
  mkdir -p "$pkg" && tar -xzf "$OUT/vps2.tar.gz" -C "$pkg"
  for f in 00-preflight 01-base 02-wireguard 03-ufw 04-ca-trust 10-docker; do
    printf 'echo "%s $*"\n' "$f" >"$pkg/common/$f.sh"
  done
  for args in 'extra' '--step' '--step 03;id' '--step $(id)' '--step 03 --step 04' '--step 03-foo' '--dry-run -x'; do
    # shellcheck disable=SC2086 # split the test arguments on purpose
    run "$pkg/vps2/install.sh" $args
    [ "$status" -eq 2 ]
    [[ $output != *preflight* && $output != *ufw* ]]
  done
  run "$pkg/vps2/install.sh" --step '03;id'
  [ "$status" -eq 2 ]
  run "$pkg/vps2/install.sh" --step 03-ssh
  [ "$output" = "03-ufw " ]
}

@test "node.env: COMPOSE_SERVICES lists only services run by Docker" {
  grep -qx 'COMPOSE_SERVICES="openbao"' "$OUT/vps1/node.env"
  grep -qx 'COMPOSE_SERVICES=""' "$OUT/vps3/node.env"
  grep -qx 'COMPOSE_SERVICES="node-agent traefik"' "$OUT/edge/node.env"
}

@test "real catalog: node-exporter listens on each machine's WG address; compose and k3s files are valid" {
  type -P kubeconform >/dev/null || skip "kubeconform not installed"
  local out="$BATS_TEST_TMPDIR/real"
  printf 'MACHINES=2\nDEVICES="laptop:linux"\nM1_NAME=edge M1_ENDPOINT=192.168.56.10\nM2_NAME=vps1 M2_ENDPOINT=192.168.56.11 M2_ARGOCD=yes M2_SERVICES="coredns step-ca openbao argocd"\n' \
    >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git --answers "$BATS_TEST_TMPDIR/a.txt"
  [ "$status" -eq 0 ]
  grep -qF -- '--web.listen-address=10.100.10.100:9100' "$out/edge/services/node-exporter/docker-compose.yml"
  grep -qF -- '--web.listen-address=10.100.10.101:9100' "$out/vps1/services/node-exporter/node-exporter.yaml"
  run ! grep -rq '0\.0\.0\.0' "$out/edge/services/node-exporter" "$out/vps1/services/node-exporter"
  grep -qx 'COMPOSE_SERVICES="coredns step-ca openbao"' "$out/vps1/node.env"
  docker compose -f "$out/edge/services/node-exporter/docker-compose.yml" config -q
  kubeconform -strict -summary "$out/vps1/services/node-exporter/node-exporter.yaml" "$out/common/argocd-rbac.yaml"
}

@test "real catalog: Traefik routes, failover with health checks, ACME from step-ca, public ports only on the edge" {
  local out="$BATS_TEST_TMPDIR/routes"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git \
    --answers "$REPO_ROOT/tests/golden/real-catalog/answers.txt"
  [ "$status" -eq 0 ]
  local routes="$out/edge/services/traefik/dynamic/routes.yml" svc main
  yq '.' "$routes" >/dev/null
  # Every failover service's main backend has a health check (failover cannot work without it).
  for svc in $(yq '.http.services | to_entries[] | select(.value.failover) | .key' "$routes"); do
    main=$(yq ".http.services.\"$svc\".failover.service" "$routes")
    [ "$(yq ".http.services.\"$main\".loadBalancer.healthCheck.path" "$routes")" = /healthz ]
  done
  [ "$(yq '.http.services | to_entries[] | select(.value.failover) | .key' "$routes")" = e-konkursy_homelab_internal ]
  [ "$(yq '.http.services.e-konkursy_homelab_internal-main.loadBalancer.servers[0].url' "$routes")" = http://10.100.10.103:80 ]
  [ "$(yq '.http.services.e-konkursy_homelab_internal-fallback.loadBalancer.servers[0].url' "$routes")" = http://10.100.10.101:80 ]
  [ "$(yq '.http.routers.pionas_dev.tls.certResolver' "$routes")" = acme ]
  grep -qF 'caServer: "https://10.100.10.101:9000/acme/acme/directory"' "$out/edge/services/traefik/traefik.yml"
  # Public (not WG-bound) port mappings: Traefik on the edge only.
  run grep -rlE '^\s+- "[0-9]+:[0-9]+"' "$out" --include=docker-compose.yml
  [ "$output" = "$out/edge/services/traefik/docker-compose.yml" ]
  grep -qF 'extra_hosts: ["e-konkursy.homelab.internal:10.100.10.100", "pionas.dev:10.100.10.100"]' \
    "$out/vps1/services/step-ca/docker-compose.yml"
  grep -qx 'e-konkursy IN A 10.100.10.100' "$out/vps1/services/coredns/db.homelab.internal"
  run ! grep -q pionas "$out/vps1/services/coredns/db.homelab.internal" # outside the zone
}

@test "no routes: Traefik gets an empty, valid dynamic configuration" {
  [ "$(yq '.http.routers | length' "$OUT/edge/services/traefik/dynamic/routes.yml")" = 0 ]
  [ "$(yq '.http.services | length' "$OUT/edge/services/traefik/dynamic/routes.yml")" = 0 ]
}

@test "real catalog: data services keep passwords out of compose files; env files are 600; ports on WG" {
  local out="$BATS_TEST_TMPDIR/data"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git \
    --answers "$REPO_ROOT/tests/golden/real-catalog/answers.txt"
  [ "$status" -eq 0 ]
  local pw f
  pw=$(sed -n 's/^POSTGRESQL_ROOT_PASSWORD=//p' "$out/vps2/secrets.env")
  [ -n "$pw" ]
  run grep -rlF "$pw" "$out/vps2/services"
  [ "$output" = "$out/vps2/services/postgresql/postgresql.env" ]
  for f in "$out"/vps2/services/*/*.env; do [ "$(stat -c %a "$f")" = 600 ]; done
  grep -qF '"10.100.10.102:5432:5432"' "$out/vps2/services/postgresql/docker-compose.yml"
  grep -qx 'DATA_SOURCE_USER=viewer' "$out/vps2/services/postgres-exporter/postgres-exporter.env"
  run ! grep -rq '0\.0\.0\.0' "$out/vps2/services/postgresql" "$out/vps2/services/postgres-exporter"
  [ "$(stat -c %a "$out/vps2/services/postgresql/install.sh")" = 755 ] # no group/other write
}

@test "real catalog: mariadb keeps passwords in mariadb.env only; exporter auto-added on the WG address" {
  local out="$BATS_TEST_TMPDIR/maria"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git \
    --answers "$REPO_ROOT/tests/golden/real-catalog/answers.txt"
  [ "$status" -eq 0 ]
  local pw
  pw=$(sed -n 's/^MARIADB_ROOT_PASSWORD=//p' "$out/vps2/secrets.env")
  run grep -rlF "$pw" "$out/vps2/services"
  [ "$output" = "$out/vps2/services/mariadb/mariadb.env" ]
  grep -qF '"10.100.10.102:3306:3306"' "$out/vps2/services/mariadb/docker-compose.yml"
  grep -qF -- '--web.listen-address=10.100.10.102:9104' "$out/vps2/services/mysqld-exporter/docker-compose.yml"
  [ "$(stat -c %a "$out/vps2/services/mariadb/initdb/10-homelab-viewer.sh")" = 644 ] # sourced, not executed
  [[ $(sed -n 's/^SERVICES=//p' "$out/vps2/node.env") == *mysqld-exporter* ]]
}

@test "real catalog: valkey ACL holds only SHA-256 hashes; default user off; viewer read-only" {
  local out="$BATS_TEST_TMPDIR/valkey"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git \
    --answers "$REPO_ROOT/tests/golden/real-catalog/answers.txt"
  [ "$status" -eq 0 ]
  local acl="$out/vps2/services/valkey/users.acl" app viewer
  app=$(sed -n 's/^VALKEY_DEFAULT_PASSWORD=//p' "$out/vps2/secrets.env")
  viewer=$(sed -n 's/^VALKEY_VIEWER_PASSWORD=//p' "$out/vps2/secrets.env")
  run ! grep -rqF "$app" "$out/vps2/services/valkey"
  run ! grep -qF "$viewer" "$acl"
  grep -qx 'user default off' "$acl"
  grep -qF "user app on #$(printf %s "$app" | sha256sum | cut -d' ' -f1) " "$acl"
  grep -qF "user viewer on #$(printf %s "$viewer" | sha256sum | cut -d' ' -f1) ~* resetchannels -@all +@read -@dangerous +info" "$acl"
  [ "$(stat -c %a "$acl")" = 600 ]
  grep -qF '"10.100.10.102:6379:6379"' "$out/vps2/services/valkey/docker-compose.yml"
  grep -qF 'REDIS_EXPORTER_WEB_LISTEN_ADDRESS: "10.100.10.102:9121"' "$out/vps2/services/redis-exporter/docker-compose.yml"
  grep -qx 'valkey IN A 10.100.10.102' "$out/vps1/services/coredns/db.homelab.internal"
}

@test "real catalog: rustfs keys only in rustfs.env; API and console on the WG address; s3. in the zone" {
  local out="$BATS_TEST_TMPDIR/rustfs"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git \
    --answers "$REPO_ROOT/tests/golden/real-catalog/answers.txt"
  [ "$status" -eq 0 ]
  local key
  key=$(sed -n 's/^RUSTFS_ROOT_PASSWORD=//p' "$out/vps2/secrets.env")
  run grep -rlF "$key" "$out/vps2/services"
  [ "$output" = "$out/vps2/services/rustfs/rustfs.env" ]
  [ "$(stat -c %a "$out/vps2/services/rustfs/rustfs.env")" = 600 ]
  grep -qF '"10.100.10.102:9000:9000"' "$out/vps2/services/rustfs/docker-compose.yml"
  grep -qF '"10.100.10.102:9001:9001"' "$out/vps2/services/rustfs/docker-compose.yml"
  grep -qx 's3 IN A 10.100.10.102' "$out/vps1/services/coredns/db.homelab.internal"
}

@test "rustfs and step-ca on one machine collide on 9000 (caught by validation)" {
  printf 'MACHINES=1\nDEVICES="laptop:linux"\nM1_NAME=edge M1_ENDPOINT=10.0.0.1 M1_SERVICES="step-ca rustfs"\n' >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --out "$BATS_TEST_TMPDIR/collide" --gitops-repo git@example.com:g.git --answers "$BATS_TEST_TMPDIR/a.txt"
  [ "$status" -ne 0 ]
  [[ $output == *"edge: port 9000/tcp used by both step-ca and rustfs"* ]]
}

@test "moved ports reach compose files, exporters, UFW ports and Traefik's ACME server" {
  local out="$BATS_TEST_TMPDIR/moved"
  sed -e 's/M2_SERVICES="coredns step-ca openbao argocd"/&\nM2_PORTS="step-ca:9000=9443"/' \
    -e 's/M3_SERVICES="[^"]*"/&\nM3_PORTS="postgresql:5432=5433 mariadb:3306=3307 valkey:6379=6380 postgres-exporter:9187=9188"/' \
    "$REPO_ROOT/tests/golden/real-catalog/answers.txt" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git --answers "$BATS_TEST_TMPDIR/a.txt"
  [ "$status" -eq 0 ]
  local s="$out/vps2/services"
  grep -qF '"10.100.10.102:5433:5432"' "$s/postgresql/docker-compose.yml"
  grep -qx 'DATA_SOURCE_URI=10.100.10.102:5433/postgres?sslmode=disable' "$s/postgres-exporter/postgres-exporter.env"
  grep -qF -- '--web.listen-address=10.100.10.102:9188' "$s/postgres-exporter/docker-compose.yml"
  grep -qF -- '--mysqld.address=10.100.10.102:3307' "$s/mysqld-exporter/docker-compose.yml"
  grep -qF 'REDIS_ADDR: "redis://10.100.10.102:6380"' "$s/redis-exporter/docker-compose.yml"
  grep -qx 'PORTS="3307 5433 6380 8081 9000 9001 9092 9100 9104 9121 9188 9644"' "$out/vps2/node.env"
  grep -qF '"10.100.10.101:9443:9000"' "$out/vps1/services/step-ca/docker-compose.yml"
  grep -qF 'caServer: "https://10.100.10.101:9443/acme/acme/directory"' "$out/edge/services/traefik/traefik.yml"
}

@test "real catalog: redpanda listens and advertises the WG address (moved port too), SASL and auth on, password only in env" {
  local out="$BATS_TEST_TMPDIR/rp"
  sed 's/M3_SERVICES="[^"]*"/&\nM3_PORTS="redpanda:9092=19092"/' \
    "$REPO_ROOT/tests/golden/real-catalog/answers.txt" >"$BATS_TEST_TMPDIR/a.txt"
  run "$REPO_ROOT/wizard.sh" --out "$out" --gitops-repo git@example.com:g.git --answers "$BATS_TEST_TMPDIR/a.txt"
  [ "$status" -eq 0 ]
  local d="$out/vps2/services/redpanda" pw
  [ "$(yq '.redpanda.kafka_api[0].address + ":" + (.redpanda.kafka_api[0].port | tostring)' "$d/redpanda.yaml")" = 10.100.10.102:19092 ]
  [ "$(yq '.redpanda.advertised_kafka_api[0].address + ":" + (.redpanda.advertised_kafka_api[0].port | tostring)' "$d/redpanda.yaml")" = 10.100.10.102:19092 ]
  [ "$(yq '.redpanda.kafka_api[0].authentication_method' "$d/redpanda.yaml")" = sasl ]
  [ "$(yq '.schema_registry.schema_registry_api[0].authentication_method' "$d/redpanda.yaml")" = http_basic ]
  [ "$(yq '.redpanda.rpc_server.address' "$d/redpanda.yaml")" = 127.0.0.1 ]
  [ "$(yq '.enable_sasl' "$d/bootstrap.yaml")" = true ]
  [ "$(yq '.admin_api_require_auth' "$d/bootstrap.yaml")" = true ]
  [ "$(yq '.superusers[0]' "$d/bootstrap.yaml")" = root ]
  pw=$(sed -n 's/^REDPANDA_ROOT_PASSWORD=//p' "$out/vps2/secrets.env")
  run grep -rlF "$pw" "$d"
  [ "$output" = "$d/redpanda.env" ]
  run ! grep -rq '0\.0\.0\.0' "$d" --exclude=docker-compose.yml
  grep -qx 'redpanda IN A 10.100.10.102' "$out/vps1/services/coredns/db.homelab.internal"
}
