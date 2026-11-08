#!/usr/bin/env bats
# Tests for lib/wg.sh on tests/fixtures/state/reference.yaml:
#   edge .100, vps1-vps5 .101-.105 (vps3: wg_port 443), laptop (linux) .200, telefon (android) .201
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  OUT="$BATS_TEST_TMPDIR/out"
  STATE="$REPO_ROOT/tests/fixtures/state/reference.yaml"
  export COUNTER="$BATS_TEST_TMPDIR/counter"
  echo 0 >"$COUNTER"
}

# in_wg SCRIPT [STATE_FILE] — loads the state, uses a deterministic key generator, saves the state to $OUT/state.yaml.
in_wg() {
  bash -c 'set -Eeuo pipefail; WG_KEYGEN=${WG_KEYGEN:-fake_key}; source "$REPO_ROOT/lib/wg.sh"
    fake_key() { local n; n=$(($(<"$COUNTER") + 1)); echo "$n" >"$COUNTER"; printf "%s" "$n" | openssl dgst -sha256 -binary | base64; }
    state_load "'"${2:-$STATE}"'"; '"$1"'
    mkdir -p "'"$OUT"'"; state_save "'"$OUT"'/state.yaml"'
}

render_all() {
  in_wg "wg_ensure_keys '$OUT'
    for m in \$(state_query '.machines[].name'); do wg_render_machine '$OUT' \$m; done
    for d in \$(state_query '.admin_devices[].name'); do wg_render_device '$OUT' \$d; done" "$@"
}

# conf_peer FILE PEER KEY — value of KEY in the [Peer] block commented "# PEER".
conf_peer() {
  awk -v p="# $2" -v k="$3" '$0 == p { on = 1; next } /^\[Peer\]/ { on = 0 } on && $1 == k { print $3 }' "$1"
}

@test "keys: generated for every participant, mode 600, public keys in the state" {
  in_wg "wg_ensure_keys '$OUT'"
  [ "$(<"$COUNTER")" = 8 ]
  for n in edge vps1 vps2 vps3 vps4 vps5 laptop telefon; do
    [ "$(stat -c %a "$OUT/wg/$n.key")" = 600 ]
    [ "$(N=$n yq '(.machines[], .admin_devices[]) | select(.name == strenv(N)) | .wg_public_key' "$OUT/state.yaml")" = \
      "$(wg pubkey <"$OUT/wg/$n.key")" ]
  done
}

@test "keys: existing private keys are kept, only new participants get one" {
  in_wg "wg_ensure_keys '$OUT'"
  cp "$OUT/wg/edge.key" "$BATS_TEST_TMPDIR/edge.key"
  in_wg "state_add_machine vps6 10.0.0.6 debian compose; wg_ensure_keys '$OUT'"
  [ "$(<"$COUNTER")" = 9 ]
  diff "$BATS_TEST_TMPDIR/edge.key" "$OUT/wg/edge.key"
}

@test "keys: default generator is wg genkey" {
  run --separate-stderr bash -c 'source "$REPO_ROOT/lib/wg.sh"; echo "$WG_KEYGEN"; wg_genkey | wg pubkey'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = wg_genkey ]
  [[ ${lines[1]} =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

@test "keys: rejects an invalid generated key and a broken key file without printing it" {
  WG_KEYGEN=bad run in_wg "bad() { echo nope; }; wg_ensure_keys '$OUT'"
  [ "$status" -eq 1 ]
  [[ $output == *"returned an invalid key for edge"* ]]
  mkdir -p "$OUT/wg" && echo 'secret-but-broken' >"$OUT/wg/edge.key"
  run in_wg "wg_ensure_keys '$OUT'"
  [ "$status" -eq 1 ]
  [[ $output == *"edge.key: not a WireGuard private key"* ]]
  [[ $output != *secret-but-broken* ]]
}

@test "mesh: every machine has every other participant with matching key and /32, never itself" {
  render_all
  local a b
  for a in edge vps1 vps2 vps3 vps4 vps5; do
    [ "$(stat -c %a "$OUT/$a/wg0.conf")" = 600 ]
    grep -qx "PrivateKey = $(<"$OUT/wg/$a.key")" "$OUT/$a/wg0.conf"
    run ! grep -qx "# $a" "$OUT/$a/wg0.conf"
    [ "$(grep -c '^\[Peer\]' "$OUT/$a/wg0.conf")" = 7 ]
    for b in edge vps1 vps2 vps3 vps4 vps5 laptop telefon; do
      [ "$a" = "$b" ] && continue
      [ "$(conf_peer "$OUT/$a/wg0.conf" "$b" PublicKey)" = "$(wg pubkey <"$OUT/wg/$b.key")" ]
      [ "$(conf_peer "$OUT/$a/wg0.conf" "$b" AllowedIPs)" = \
        "$(N=$b yq '(.machines[], .admin_devices[]) | select(.name == strenv(N)) | .wg_ip' "$STATE")/32" ]
    done
  done
}

@test "ports: ListenPort is the machine's wg_port, Endpoint uses each peer's own endpoint and port" {
  render_all
  grep -qx 'ListenPort = 443' "$OUT/vps3/wg0.conf"
  grep -qx 'ListenPort = 51820' "$OUT/vps1/wg0.conf"
  [ "$(conf_peer "$OUT/vps1/wg0.conf" vps3 Endpoint)" = 192.168.56.13:443 ]
  [ "$(conf_peer "$OUT/vps3/wg0.conf" edge Endpoint)" = 192.168.56.10:51820 ]
  [ "$(conf_peer "$OUT/admin-devices/laptop/laptop.conf" vps3 Endpoint)" = 192.168.56.13:443 ]
}

@test "admin devices: no Endpoint in machine configs" {
  render_all
  [ -z "$(conf_peer "$OUT/vps1/wg0.conf" laptop Endpoint)" ]
  [ -z "$(conf_peer "$OUT/edge/wg0.conf" telefon Endpoint)" ]
}

@test "IPv6 endpoints are bracketed" {
  yq '.machines[1].endpoint = "2001:db8::1"' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  render_all "$BATS_TEST_TMPDIR/s.yaml"
  [ "$(conf_peer "$OUT/edge/wg0.conf" vps1 Endpoint)" = '[2001:db8::1]:51820' ]
}

@test "device config: all machines with Endpoint and keepalive, no other devices, DNS on the edge without coredns" {
  render_all
  local conf="$OUT/admin-devices/laptop/laptop.conf"
  [ "$(stat -c %a "$conf")" = 600 ]
  grep -qx 'DNS = 10.100.10.100' "$conf"
  [ "$(grep -c '^\[Peer\]' "$conf")" = 6 ]
  [ "$(grep -c '^PersistentKeepalive = 25$' "$conf")" = 6 ]
  run ! grep -qx '# telefon' "$conf"
}

@test "device config: DNS is the WG address of the machine with coredns" {
  yq '.machines[2].services += ["coredns"]' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  render_all "$BATS_TEST_TMPDIR/s.yaml"
  grep -qx 'DNS = 10.100.10.102' "$OUT/admin-devices/laptop/laptop.conf"
}

@test "QR code (mode 600) only for ios and android" {
  yq '.admin_devices[0].type = "ios"' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  render_all "$BATS_TEST_TMPDIR/s.yaml"
  for d in laptop telefon; do
    [ "$(stat -c %a "$OUT/admin-devices/$d/$d.png")" = 600 ]
    [ "$(head -c 4 "$OUT/admin-devices/$d/$d.png" | tail -c 3)" = PNG ]
  done
}

@test "no QR code for linux and windows devices" {
  yq '.admin_devices[1].type = "windows"' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  render_all "$BATS_TEST_TMPDIR/s.yaml"
  [ ! -e "$OUT/admin-devices/laptop/laptop.png" ]
  [ ! -e "$OUT/admin-devices/telefon/telefon.png" ]
}

@test "rendering needs keys and a known name" {
  run in_wg "wg_render_machine '$OUT' edge"
  [ "$status" -eq 1 ]
  [[ $output == *"no WireGuard key for: edge"* ]]
  run in_wg "wg_ensure_keys '$OUT'; wg_render_machine '$OUT' nope"
  [[ $output == *"unknown machine: nope"* ]]
  run in_wg "wg_ensure_keys '$OUT'; wg_render_device '$OUT' edge"
  [[ $output == *"unknown admin device: edge"* ]]
}

@test "wg_peers_to_update: every machine except the new one" {
  run --separate-stderr in_wg 'wg_peers_to_update vps3'
  [ "$output" = $'edge\nvps1\nvps2\nvps4\nvps5' ]
}

@test "state validation rejects a malformed wg_public_key" {
  yq '.machines[1].wg_public_key = "short"' "$STATE" >"$BATS_TEST_TMPDIR/s.yaml"
  run bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/state.sh"
    state_validate "'"$BATS_TEST_TMPDIR"'/s.yaml" "$REPO_ROOT/tests/fixtures/catalog-valid"'
  [ "$status" -eq 1 ]
  [[ $output == *"'vps1': wg_public_key is not a WireGuard key"* ]]
}
