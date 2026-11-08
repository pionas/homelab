#!/usr/bin/env bats
# Tests for lib/secrets.sh on tests/fixtures/state/reference.yaml with tests/fixtures/catalog-valid:
#   edge: node-agent proxy (no secrets)      vps1: db (+db-exporter -> DB:VIEWER, log-shipper)
#   vps2: cache (DEFAULT) vault (ROOT)        vps3-vps5: gitops / app-cluster (no secrets)
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  OUT="$BATS_TEST_TMPDIR/out"
  STATE="$REPO_ROOT/tests/fixtures/state/reference.yaml"
  # Deterministic generator: pass-1, pass-2, ... (counter in a file, it runs in a subshell).
  export COUNTER="$BATS_TEST_TMPDIR/counter"
  echo 0 >"$COUNTER"
}

# in_secrets SCRIPT [STATE_FILE] — runs SCRIPT with the fixture catalog and state loaded.
in_secrets() {
  bash -c 'set -Eeuo pipefail; SECRETS_GENERATOR=${SECRETS_GENERATOR:-fake_pass}; source "$REPO_ROOT/lib/secrets.sh"
    fake_pass() { local n; n=$(($(<"$COUNTER") + 1)); echo "$n" >"$COUNTER"; echo "pass-$n"; }
    catalog_load "$REPO_ROOT/tests/fixtures/catalog-valid"; state_load "'"${2:-$STATE}"'"; '"$1"
}

generate() { in_secrets "secrets_generate '$OUT'"; }

@test "secrets_prefix: uppercase, - becomes _" {
  run in_secrets 'secrets_prefix postgres-exporter; secrets_prefix db'
  [ "$output" = $'POSTGRES_EXPORTER\nDB' ]
}

@test "secrets.env has every account of the state's services, with usernames" {
  generate
  run cat "$OUT/secrets.env"
  [ "$output" = "CACHE_DEFAULT_PASSWORD=pass-1
CACHE_DEFAULT_USERNAME=app
DB_DEFAULT_PASSWORD=pass-2
DB_DEFAULT_USERNAME=app
DB_ROOT_PASSWORD=pass-3
DB_ROOT_USERNAME=root
DB_VIEWER_PASSWORD=pass-4
DB_VIEWER_USERNAME=viewer
VAULT_ROOT_PASSWORD=pass-5
VAULT_ROOT_USERNAME=root" ]
}

@test "machine file: own services + AUTO_ADD + USES_SECRETS only; edge gets no database passwords" {
  generate
  in_secrets "for m in edge vps1 vps2; do secrets_for_machine '$OUT' \$m; done"
  [ ! -s "$OUT/edge/secrets.env" ]
  run cut -d= -f1 "$OUT/vps1/secrets.env"
  [ "$output" = $'DB_DEFAULT_PASSWORD\nDB_DEFAULT_USERNAME\nDB_ROOT_PASSWORD\nDB_ROOT_USERNAME\nDB_VIEWER_PASSWORD\nDB_VIEWER_USERNAME' ]
  run cut -d= -f1 "$OUT/vps2/secrets.env"
  [ "$output" = $'CACHE_DEFAULT_PASSWORD\nCACHE_DEFAULT_USERNAME\nVAULT_ROOT_PASSWORD\nVAULT_ROOT_USERNAME' ]
  grep -qx 'DB_ROOT_PASSWORD=pass-3' "$OUT/vps1/secrets.env"
}

@test "USES_SECRETS alone gives only the used account" {
  yq '.machines[1].services = ["db-exporter"] | .machines[2].services += ["db"]' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  in_secrets "secrets_generate '$OUT'; secrets_for_machine '$OUT' vps1" "$BATS_TEST_TMPDIR/s.yaml"
  run cut -d= -f1 "$OUT/vps1/secrets.env"
  [ "$output" = $'DB_VIEWER_PASSWORD\nDB_VIEWER_USERNAME' ]
}

@test "files are mode 600, also when they existed with wider permissions" {
  mkdir -p "$OUT/vps1" && touch "$OUT/secrets.env" "$OUT/vps1/secrets.env"
  chmod 644 "$OUT/secrets.env" "$OUT/vps1/secrets.env"
  in_secrets "secrets_generate '$OUT'; secrets_for_machine '$OUT' vps1; secrets_for_machine '$OUT' vps2"
  [ "$(stat -c %a "$OUT/secrets.env")" = 600 ]
  [ "$(stat -c %a "$OUT/vps1/secrets.env")" = 600 ]
  [ "$(stat -c %a "$OUT/vps2/secrets.env")" = 600 ]
  [ "$(stat -c %a "$OUT/vps2")" = 700 ] # created by the library
}

@test "a second run does not change existing passwords" {
  generate
  cp "$OUT/secrets.env" "$BATS_TEST_TMPDIR/first"
  generate
  diff "$BATS_TEST_TMPDIR/first" "$OUT/secrets.env"
}

@test "adding a machine with a new service keeps old passwords and generates only the new ones" {
  yq '.machines[2].services = ["cache"]' "$STATE" >"$BATS_TEST_TMPDIR/before.yaml"
  in_secrets "secrets_generate '$OUT'" "$BATS_TEST_TMPDIR/before.yaml"
  cp "$OUT/secrets.env" "$BATS_TEST_TMPDIR/first"
  yq '.machines[2].services = ["cache"] | .machines += [{"name": "vps6", "endpoint": "10.0.0.6", "os": "debian",
    "runtime": "compose", "wg_ip": "10.100.10.106", "wg_port": 51820, "ssh_port": 22, "services": ["vault"]}]' \
    "$STATE" >"$BATS_TEST_TMPDIR/after.yaml"
  in_secrets "secrets_generate '$OUT'" "$BATS_TEST_TMPDIR/after.yaml"
  run diff "$BATS_TEST_TMPDIR/first" "$OUT/secrets.env"
  [ "$output" = $'8a9,10\n> VAULT_ROOT_PASSWORD=pass-5\n> VAULT_ROOT_USERNAME=root' ]
}

@test "secrets of a service removed from the state are kept" {
  generate
  yq '.machines[2].services = []' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  in_secrets "secrets_generate '$OUT'" "$BATS_TEST_TMPDIR/s.yaml"
  grep -qx 'VAULT_ROOT_PASSWORD=pass-5' "$OUT/secrets.env"
}

@test "default generator: openssl, only safe characters" {
  run --separate-stderr in_secrets 'for i in 1 2 3; do secrets_random; echo; done'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  for l in "${lines[@]}"; do [[ $l =~ ^[A-Za-z0-9]{30,}$ ]]; done
  [ "${lines[0]}" != "${lines[1]}" ]
}

@test "rejects a generated value that would break sourcing" {
  SECRETS_GENERATOR=bad run in_secrets "bad() { echo 'a\$b c'; }; secrets_generate '$OUT'"
  [ "$status" -eq 1 ]
  [[ $output == *"generated value for CACHE_DEFAULT_PASSWORD is empty or has characters outside"* ]]
  [[ $output != *'a$b'* ]]
  [ ! -e "$OUT/secrets.env" ]
}

@test "rejects a broken secrets.env without printing its content" {
  mkdir -p "$OUT" && printf 'DB_ROOT_PASSWORD=sec ret\n' >"$OUT/secrets.env"
  run generate
  [ "$status" -eq 1 ]
  [[ $output == *"secrets.env:1: expected NAME=value"* ]]
  [[ $output != *"sec ret"* ]]
  grep -qx 'DB_ROOT_PASSWORD=sec ret' "$OUT/secrets.env" # left untouched
}

@test "machine file needs generated secrets and a known machine" {
  run in_secrets "secrets_for_machine '$OUT' vps1"
  [ "$status" -eq 1 ]
  [[ $output == *"vps1: DB_DEFAULT_PASSWORD missing"* ]]
  run in_secrets "secrets_for_machine '$OUT' nope"
  [ "$status" -eq 1 ]
  [[ $output == *"unknown machine: nope"* ]]
}

@test "secret values never appear in the log" {
  run --separate-stderr in_secrets "LOG_LEVEL=debug; secrets_generate '$OUT'; secrets_for_machine '$OUT' vps1"
  [ "$status" -eq 0 ]
  [[ $stderr$output != *pass-* ]]
}
