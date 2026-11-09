#!/usr/bin/env bats
# Tests for lib/state.sh. Fixtures: tests/fixtures/state (service ids from tests/fixtures/catalog-valid)
#   one-machine.yaml  edge only
#   reference.yaml    edge + vps1-vps5 (vps3: wg_port 443, ssh_port 2222) + laptop, telefon
#   duplicate-name.yaml, bad-runtime.yaml, unknown-service.yaml, bad-port.yaml — one broken thing each
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  ST="$REPO_ROOT/tests/fixtures/state"
  CAT="$REPO_ROOT/tests/fixtures/catalog-valid"
}

in_state() {
  bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/state.sh"; '"$1"
}

# on_new SCRIPT — runs SCRIPT on a fresh state; stdout only in $output.
on_new() {
  run --separate-stderr in_state "state_init git@example.com:gitops.git compose; $1"
}

expect_state_invalid() {
  run in_state "state_validate '$1' '$CAT'"
  [ "$status" -eq 1 ]
  [[ $output == *"$2"* ]]
}

# --- load / save ------------------------------------------------------------

@test "roundtrip: load then save gives an identical file" {
  for f in one-machine reference; do
    run in_state "state_load '$ST/$f.yaml'; state_save '$BATS_TEST_TMPDIR/$f.yaml'"
    [ "$status" -eq 0 ]
    diff "$ST/$f.yaml" "$BATS_TEST_TMPDIR/$f.yaml"
  done
}

@test "state_load rejects a missing file and a non-mapping" {
  run in_state "state_load '$BATS_TEST_TMPDIR/none.yaml'"
  [ "$status" -eq 1 ]
  [[ $output == *"state file not found"* ]]
  echo '- a' >"$BATS_TEST_TMPDIR/list.yaml"
  run in_state "state_load '$BATS_TEST_TMPDIR/list.yaml'"
  [ "$status" -eq 1 ]
  [[ $output == *"must be a YAML mapping"* ]]
}

# --- model ------------------------------------------------------------------

@test "model has all fields of the state" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'; state_query '
    (keys | join(\",\")), (.machines[0] | keys | join(\",\")), (.admin_devices[0] | keys | join(\",\"))'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "gitops_repo,default_runtime,machines,admin_devices" ]
  [ "${lines[1]}" = "name,endpoint,os,runtime,wg_ip,wg_port,ssh_port,services" ]
  [ "${lines[2]}" = "name,type,wg_ip" ]
}

@test "the valid fixtures pass validation" {
  for f in one-machine reference; do
    run in_state "state_validate '$ST/$f.yaml' '$CAT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

# --- WG addresses -----------------------------------------------------------

@test "edge is .100, next machines .101+, devices .200+" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose; state_add_machine vps1 10.0.0.2 debian k3s
    state_add_device laptop linux; state_query ".machines[].wg_ip, .admin_devices[].wg_ip"'
  [ "$status" -eq 0 ]
  [ "$output" = $'10.100.10.100\n10.100.10.101\n10.100.10.200' ]
}

@test "adding a machine keeps existing addresses and fills the first gap" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'
    before=\$(state_query '.machines[].wg_ip')
    _STATE=\$(yq 'del(.machines[2])' <<<\"\$_STATE\") # vps2 (.102) removed -> gap
    state_add_machine vps6 10.0.0.6 debian compose
    state_query '.machines[] | .name + \" \" + .wg_ip'"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "vps1 10.100.10.101" ]
  [ "${lines[2]}" = "vps3 10.100.10.103" ]
  [ "${lines[5]}" = "vps6 10.100.10.102" ]
}

@test "exhausted machine range (.101-.199) gives a readable error" {
  on_new 'for i in $(seq 0 99); do state_add_machine "m$i" "10.0.0.$i" debian compose; done
    state_add_machine one-too-many 10.0.1.1 debian compose'
  [ "$status" -eq 1 ]
  [[ $stderr == *"no free WG address in 10.100.10.101-199"* ]]
}

@test "exhausted device range (.200-.254) gives a readable error" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose
    for i in $(seq 200 254); do state_add_device "d$i" linux; done; state_add_device one-too-many ios'
  [ "$status" -eq 1 ]
  [[ $stderr == *"no free WG address in 10.100.10.200-254"* ]]
}

# --- ports ------------------------------------------------------------------

@test "edge defaults to wg_port 51820 and ssh_port 22" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose; state_query ".machines[0] | [.wg_port, .ssh_port] | join(\" \")"'
  [ "$output" = "51820 22" ]
}

@test "a new machine without ports takes the edge wg_port and ssh_port 22; given ports override" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose 443 2200
    state_add_machine vps1 10.0.0.2 debian compose
    state_add_machine vps2 10.0.0.3 debian compose 8443 2222
    state_query ".machines[] | [.wg_port, .ssh_port] | join(\" \")"'
  [ "$status" -eq 0 ]
  [ "$output" = $'443 2200\n443 22\n8443 2222' ]
}

@test "changing the edge wg_port does not change other machines" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'
    _STATE=\$(yq '.machines[0].wg_port = 1234' <<<\"\$_STATE\")
    state_add_machine vps6 10.0.0.6 debian compose
    state_query '.machines[] | .wg_port'"
  [ "$output" = $'1234\n51820\n51820\n443\n51820\n51820\n1234' ]
}

@test "rejects invalid ports when adding a machine and keeps the state" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose
    for p in abc 0 65536; do state_add_machine vps1 10.0.0.2 debian compose "$p" && exit 9; done
    state_add_machine vps1 10.0.0.2 debian compose 51820 -1 && exit 9
    state_query ".machines | length"'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [[ $stderr == *"wg_port must be an integer 1-65535, got: 'abc'"* ]]
  [[ $stderr == *"ssh_port must be an integer 1-65535, got: '-1'"* ]]
}

@test "validation: ports out of range or not integers" {
  expect_state_invalid "$ST/bad-port.yaml" "machine 'vps3': wg_port must be an integer 1-65535, got: '70000'"
  [[ $output == *"machine 'vps3': ssh_port must be an integer 1-65535, got: '22'"* ]]
}

# --- validation -------------------------------------------------------------

@test "validation: duplicate names" {
  expect_state_invalid "$ST/duplicate-name.yaml" "duplicate name: edge"
}

@test "validation: runtime must be compose or k3s" {
  expect_state_invalid "$ST/bad-runtime.yaml" "machine 'vps2': runtime must be compose or k3s, got: 'podman'"
}

@test "validation: services must exist in the catalog" {
  expect_state_invalid "$ST/unknown-service.yaml" "machine 'vps1': unknown service nope"
}

@test "validation reports all errors, not just the first" {
  yq '.machines[1].name = "edge" | .machines[2].runtime = "podman" | .machines[3].services += ["nope"]' \
    "$ST/reference.yaml" >"$BATS_TEST_TMPDIR/many.yaml"
  expect_state_invalid "$BATS_TEST_TMPDIR/many.yaml" "duplicate name: edge"
  [[ $output == *"runtime must be compose or k3s"* ]]
  [[ $output == *"unknown service nope"* ]]
}

@test "validation: names must be safe path components" {
  yq '.machines[1].name = "../etc" | .admin_devices[0].name = "a b"' "$ST/reference.yaml" >"$BATS_TEST_TMPDIR/n.yaml"
  expect_state_invalid "$BATS_TEST_TMPDIR/n.yaml" "name must be lowercase [a-z0-9-], got: '../etc'"
  [[ $output == *"got: 'a b'"* ]]
}

@test "validation: edge address, address ranges and device type" {
  yq '.machines[0].wg_ip = "10.100.10.101" | .machines[1].wg_ip = "10.100.10.250" |
    .admin_devices[0].type = "mac"' "$ST/reference.yaml" >"$BATS_TEST_TMPDIR/ip.yaml"
  expect_state_invalid "$BATS_TEST_TMPDIR/ip.yaml" "the edge (first machine) must have wg_ip 10.100.10.100"
  [[ $output == *"machine 'vps1': wg_ip must be in 10.100.10.101-199, got: '10.100.10.250'"* ]]
  [[ $output == *"type must be windows|ios|android|linux, got: 'mac'"* ]]
}

@test "validation: empty state has no machines" {
  on_new "state_save '$BATS_TEST_TMPDIR/empty.yaml'"
  expect_state_invalid "$BATS_TEST_TMPDIR/empty.yaml" "no machines"
}

@test "state_set_services rejects an unknown machine" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose; state_set_services nope proxy'
  [ "$status" -eq 1 ]
  [[ $stderr == *"unknown machine: nope"* ]]
}

@test "values with yq syntax are stored as data" {
  on_new 'state_add_machine edge 10.0.0.1 debian compose; state_set_services edge "\") | .x = (\""
    state_query "(.machines[0].services | length), has(\"x\")"'
  [ "$status" -eq 0 ]
  [ "$output" = $'5\nfalse' ]
}

# --- routes -----------------------------------------------------------------

@test "routes: added with defaults (port 80, /healthz), fallback only when given" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'
    state_add_route app.homelab.internal vps3 vps4; state_add_route b.example.org vps3
    state_query '.routes[] | [.host, .machine, .fallback // \"-\", .port, .health_path] | join(\" \")'"
  [ "$status" -eq 0 ]
  [ "$output" = $'app.homelab.internal vps3 vps4 80 /healthz\nb.example.org vps3 - 80 /healthz' ]
}

@test "routes: rejects duplicate host, unknown or same fallback, bad host; state unchanged" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'; state_add_route a.example.org vps3
    state_add_route a.example.org vps1 && exit 9
    state_add_route b.example.org vps1 vps1 && exit 9
    state_add_route c.example.org nope && exit 9
    state_add_route 'Bad Host' vps1 && exit 9
    state_query '.routes | length'"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [[ $stderr == *"duplicate route host: a.example.org"* && $stderr == *"fallback must be another known machine"* ]]
  [[ $stderr == *"unknown machine 'nope'"* && $stderr == *"route host must be a lowercase domain name"* ]]
}

@test "routes: port and health path from the file are validated" {
  yq '.routes = [{"host": "a.example.org", "machine": "vps3", "port": 70000, "health_path": "x;y"}]' \
    "$ST/reference.yaml" >"$BATS_TEST_TMPDIR/r.yaml"
  expect_state_invalid "$BATS_TEST_TMPDIR/r.yaml" "route 'a.example.org': port must be an integer 1-65535"
  [[ $output == *"health_path must be a URL path, got: 'x;y'"* ]]
}

# --- port overrides ------------------------------------------------------------

@test "ports: state_port gives the override or the default; overrides are stored per machine and service" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'
    state_set_port_override vps2 db 5432 5433
    state_port vps2 db 5432; state_port vps2 db 9999; state_port vps1 db 5432
    state_query '.machines[2].port_overrides.db.\"5432\"'"
  [ "$status" -eq 0 ]
  [ "$output" = $'5433\n9999\n5432\n5433' ]
}

@test "ports: overrides must be numbers 1-65535" {
  run --separate-stderr in_state "state_load '$ST/reference.yaml'
    state_set_port_override vps2 db 5432 x && exit 9
    state_set_port_override vps2 db 5432 70000 && exit 9
    state_query '.machines[2] | has(\"port_overrides\")'"
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  [[ $stderr == *"ports must be numbers"* && $stderr == *"port override db:5432 must be an integer 1-65535, got: '70000'"* ]]
}
