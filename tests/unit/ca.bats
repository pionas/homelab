#!/usr/bin/env bats
# Tests for lib/ca.sh on tests/fixtures/state/reference.yaml (k3s machines: vps3, vps4, vps5).
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  type -P step >/dev/null || skip "step (step-cli) not installed"
  OUT="$BATS_TEST_TMPDIR/out"
  STATE="$REPO_ROOT/tests/fixtures/state/reference.yaml"
}

in_ca() {
  bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/ca.sh"; state_load "'"$STATE"'"; '"$1"
}

ensure_all() { in_ca "ca_ensure_root '$OUT'; ca_ensure_intermediate '$OUT'; ca_ensure_k3s_cluster '$OUT' vps3"; }

@test "root and intermediate: intermediate verifies against root, keys are mode 600" {
  ensure_all
  openssl verify -CAfile "$OUT/ca/root_ca.crt" "$OUT/ca/intermediate_ca.crt"
  step certificate verify "$OUT/ca/intermediate_ca.crt" --roots "$OUT/ca/root_ca.crt"
  [ "$(openssl x509 -in "$OUT/ca/root_ca.crt" -noout -subject)" = "subject=CN=Homelab Root CA" ]
  for k in "$OUT"/ca/*.key; do [ "$(stat -c %a "$k")" = 600 ]; done
}

@test "a second run does not change any CA file" {
  ensure_all
  (cd "$OUT" && find . -type f -exec sha256sum {} + | sort) >"$BATS_TEST_TMPDIR/first"
  ensure_all
  (cd "$OUT" && find . -type f -exec sha256sum {} + | sort) >"$BATS_TEST_TMPDIR/second"
  diff "$BATS_TEST_TMPDIR/first" "$BATS_TEST_TMPDIR/second"
}

@test "a lone certificate or key is an error, never regenerated" {
  ensure_all
  rm "$OUT/ca/root_ca.key"
  cp "$OUT/ca/root_ca.crt" "$BATS_TEST_TMPDIR/root.crt"
  run in_ca "ca_ensure_root '$OUT'"
  [ "$status" -eq 1 ]
  [[ $output == *"incomplete CA: only one of"*"root_ca.crt"* ]]
  diff "$BATS_TEST_TMPDIR/root.crt" "$OUT/ca/root_ca.crt"
  rm "$OUT/k3s-ca/vps3/argocd.crt"
  run in_ca "ca_ensure_k3s_cluster '$OUT' vps3"
  [ "$status" -eq 1 ]
  [[ $output == *"incomplete CA"*"argocd"* ]]
}

@test "intermediate needs the root" {
  run in_ca "ca_ensure_intermediate '$OUT'"
  [ "$status" -eq 1 ]
  [[ $output == *"root CA missing"* ]]
}

@test "k3s cluster: every file k3s needs before first start, keys mode 600" {
  ensure_all
  local f
  for f in server-ca client-ca request-header-ca etcd/peer-ca etcd/server-ca; do
    openssl x509 -in "$OUT/k3s-ca/vps3/$f.crt" -noout -ext basicConstraints | grep -q 'CA:TRUE'
    [ "$(stat -c %a "$OUT/k3s-ca/vps3/$f.key")" = 600 ]
  done
  openssl pkey -in "$OUT/k3s-ca/vps3/service.key" -noout
  [ "$(stat -c %a "$OUT/k3s-ca/vps3/service.key")" = 600 ]
}

@test "k3s cluster: argocd client certificate is signed by client-ca, not by the homelab root" {
  ensure_all
  local d="$OUT/k3s-ca/vps3"
  openssl verify -CAfile "$d/client-ca.crt" -purpose sslclient "$d/argocd.crt"
  [ "$(openssl x509 -in "$d/argocd.crt" -noout -subject)" = "subject=CN=argocd" ]
  run openssl verify -CAfile "$OUT/ca/root_ca.crt" "$d/client-ca.crt"
  [ "$status" -ne 0 ]
  # argocd certificate must outlive a year (renewal is not automated)
  openssl x509 -in "$d/argocd.crt" -noout -checkend $((5 * 365 * 24 * 3600))
}

@test "k3s clusters have separate CAs" {
  in_ca "ca_ensure_k3s_cluster '$OUT' vps3; ca_ensure_k3s_cluster '$OUT' vps4"
  run openssl verify -CAfile "$OUT/k3s-ca/vps3/client-ca.crt" "$OUT/k3s-ca/vps4/argocd.crt"
  [ "$status" -ne 0 ]
}

@test "k3s cluster: rejects a compose or unknown machine" {
  run in_ca "ca_ensure_k3s_cluster '$OUT' vps1"
  [ "$status" -eq 1 ]
  [[ $output == *"not a k3s machine: vps1"* ]]
  [ ! -e "$OUT/k3s-ca/vps1" ]
}

@test "package file lists: root key in none, public list only the root certificate" {
  ensure_all
  run in_ca "ca_files_public '$OUT'; ca_files_step_ca '$OUT'; ca_files_k3s '$OUT' vps3; ca_files_argocd '$OUT' vps3"
  [ "$status" -eq 0 ]
  [[ $output != *root_ca.key* ]]
  [ "${lines[0]}" = "$OUT/ca/root_ca.crt" ]
  for f in "${lines[@]}"; do [ -e "$f" ]; done
  run in_ca "ca_files_public '$OUT'"
  [ "$output" = "$OUT/ca/root_ca.crt" ]
}

@test "missing step gives install instructions" {
  run env PATH=/usr/bin:/bin bash -c 'source "$REPO_ROOT/lib/ca.sh"; ca_ensure_root "'"$OUT"'"'
  if [[ -x /usr/bin/step || -x /bin/step ]]; then skip "step installed system-wide"; fi
  [ "$status" -eq 1 ]
  [[ $output == *"missing tool: step"*"https://github.com/smallstep/cli/releases"* ]]
  [ ! -e "$OUT/ca" ]
}
