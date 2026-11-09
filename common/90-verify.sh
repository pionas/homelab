#!/usr/bin/env bash
# Step 90: checks that the installed machine works. Read-only and without a marker: run it any time.
# Reports every problem and fails if there is one. The check from outside (nmap) is manual:
# docs/weryfikacja.md.
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

CA_BUNDLE=${HOMELAB_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
[[ $CA_BUNDLE == /* && $CA_BUNDLE != *..* ]] || die "HOMELAB_CA_BUNDLE must be an absolute path without .."
# Throwaway pod for the pod -> compose service check (pinned image).
VERIFY_POD_IMAGE=busybox:1.37.0
VERIFY_POD=homelab-verify

FAILED=0
ok() { log_info "verify OK: $*"; }
bad() {
  log_error "verify FAILED: $*"
  FAILED=1
}

verify_wireguard() {
  local port
  if ! port=$(wg show wg0 listen-port 2>/dev/null); then
    bad "WireGuard interface wg0 is not up (systemctl status wg-quick@wg0)"
    return 0
  fi
  if [[ $port == "$WG_PORT" ]]; then ok "wg0 listens on $WG_PORT/udp"; else bad "wg0 listens on $port, expected $WG_PORT"; fi
  local total=0 silent=0 ts
  while IFS=$'\t' read -r _ ts; do
    total=$((total + 1))
    if ((ts == 0)); then silent=$((silent + 1)); fi
  done < <(wg show wg0 latest-handshakes)
  # Peers that are not installed yet have no handshake: worth knowing, not a failure.
  if ((silent)); then log_warn "$silent of $total WireGuard peers without a handshake yet"; else ok "all $total peers have a handshake"; fi
}

verify_ssh() {
  local port
  port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
  if [[ $port == "$SSH_PORT" ]]; then ok "sshd on port $SSH_PORT"; else bad "sshd on port ${port:-?}, expected $SSH_PORT"; fi
}

verify_firewall() {
  if ufw status 2>/dev/null | grep -q '^Status: active'; then ok "UFW active"; else bad "UFW is not active"; fi
}

verify_ca() {
  if openssl verify -CAfile "$CA_BUNDLE" "$HOMELAB_COMMON_DIR/root_ca.crt" >/dev/null 2>&1; then
    ok "homelab root CA trusted by the system"
  else
    bad "homelab root CA is not in $CA_BUNDLE (step 04)"
  fi
}

verify_k3s() {
  [[ $RUNTIME == k3s ]] || return 0
  if in_container; then
    container_skip "k3s checks (k3s is not started in a container)"
    return 0
  fi
  if ! k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
    bad "k3s API is not ready (journalctl -u k3s)"
    return 0
  fi
  ok "k3s API ready"
  if cmp -s "$HOMELAB_NODE_DIR/k3s-ca/$NODE_NAME/server-ca.crt" "$HOMELAB_K3S_DATA_DIR/server/tls/server-ca.crt"; then
    ok "k3s uses the cluster CA from the wizard"
  else
    bad "k3s server CA differs from the package: ArgoCD will not connect"
  fi
  verify_pod_to_compose
}

# Pods reach compose services on the same machine from 10.42/16, through Docker's and k3s's
# iptables rules and UFW: test every service port on the WireGuard address from a pod.
verify_pod_to_compose() {
  [[ -n ${COMPOSE_SERVICES:-} && -n ${PORTS:-} ]] || return 0
  local result port
  # PORTS are validated numbers (load_node_env), so the pod script holds no other input.
  result=$(k3s kubectl run "$VERIFY_POD" --rm -i --quiet --restart=Never --image="$VERIFY_POD_IMAGE" \
    --command -- sh -c "for p in $PORTS; do nc -z -w 3 $WG_IP \$p && echo ok:\$p || echo fail:\$p; done" 2>&1) || true
  for port in $PORTS; do
    if grep -qx "ok:$port" <<<"$result"; then ok "pod -> $WG_IP:$port"; else bad "pod cannot reach $WG_IP:$port"; fi
  done
}

verify_node_exporter() {
  [[ " ${SERVICES:-} " == *" node-exporter "* ]] || return 0
  if in_container; then
    container_skip "node_exporter check (it does not run in a container)"
    return 0
  fi
  if curl -fsS --max-time 5 "http://$WG_IP:9100/metrics" | grep -q '^node_exporter_build_info'; then
    ok "node_exporter on $WG_IP:9100"
  else
    bad "node_exporter does not answer on $WG_IP:9100"
  fi
}

verify_wireguard
verify_ssh
verify_firewall
verify_ca
verify_k3s
verify_node_exporter
((FAILED == 0)) || die "verification of $NODE_NAME failed, see the errors above"
log_info "verification of $NODE_NAME passed"
