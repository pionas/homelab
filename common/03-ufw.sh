#!/usr/bin/env bash
# Step 03: UFW firewall. Step 03-ssh: close public SSH, but only once an admin path over WireGuard
# is proven, and with a timer that reopens it after 5 minutes unless cancelled.
# Order matters: SSH is allowed before UFW is enabled, or this session is cut off on the spot.
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

ROLLBACK_UNIT=homelab-ssh-rollback
ROLLBACK_DELAY=5min
# An admin device counts as connected when its last handshake is this recent.
ADMIN_HANDSHAKE_MAX_AGE=120
WG_PREFIX=${HOMELAB_WG_NET%.*}.
# k3s pod and service networks; pods reach compose services on the same machine from 10.42/16.
K3S_POD_NET=10.42.0.0/16
K3S_SERVICE_NET=10.43.0.0/16
K3S_API_PORT=6443

ssh_session

firewall() {
  local current=$SSH_SERVER_PORT port
  if step_is_done 03-ssh; then
    log_info "public SSH was closed by step 03-ssh; keeping it closed"
  else
    run ufw allow "$SSH_PORT/tcp" comment homelab-ssh-public
    # sshd may have moved in step 01 while this session stays on the old port until 03-ssh.
    if [[ -n $current && $current != "$SSH_PORT" ]]; then
      run ufw allow "$current/tcp" comment homelab-ssh-session
    fi
  fi
  run ufw allow from "$HOMELAB_WG_NET" to any port "$SSH_PORT" proto tcp comment homelab-ssh-wg
  run ufw allow "$WG_PORT/udp" comment homelab-wireguard
  for port in ${PUBLIC_PORTS:-}; do
    run ufw allow "$port/tcp" comment homelab-public
  done
  # TCP and UDP: some services need UDP (DNS on 53), and the WireGuard network is trusted.
  for port in ${PORTS:-}; do
    run ufw allow from "$HOMELAB_WG_NET" to any port "$port" comment homelab-service
  done
  if [[ $RUNTIME == k3s ]]; then
    run ufw allow from "$K3S_POD_NET" comment homelab-k3s-pods
    run ufw allow from "$K3S_SERVICE_NET" comment homelab-k3s-services
    run ufw allow from "$HOMELAB_WG_NET" to any port "$K3S_API_PORT" proto tcp comment homelab-k3s-api
    # The k3s Traefik ingress (panels such as ArgoCD): VPN only, never public.
    for port in 80 443; do
      run ufw allow from "$HOMELAB_WG_NET" to any port "$port" proto tcp comment homelab-k3s-ingress
    done
  fi
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw --force enable
}

session_over_wg() { [[ -n $SSH_CLIENT_IP && $SSH_CLIENT_IP == "$WG_PREFIX"* ]]; }

# Proof that an admin can still get in once public SSH is closed: this session comes over
# WireGuard, or an admin device (.200-.254) has a fresh handshake.
admin_path_ok() {
  if session_over_wg; then
    log_info "this SSH session comes over WireGuard"
    return 0
  fi
  local now pub ip ts octet
  local -A ip_of=()
  now=$(date +%s)
  while IFS=$'\t' read -r pub ip; do
    ip_of[$pub]=${ip%%/*}
  done < <(wg show wg0 allowed-ips 2>/dev/null || true)
  while IFS=$'\t' read -r pub ts; do
    ip=${ip_of[$pub]-}
    octet=${ip#"$WG_PREFIX"}
    [[ $ip == "$WG_PREFIX"* && $octet =~ ^[0-9]+$ ]] || continue
    if ((octet >= 200 && octet <= 254 && ts > 0 && now - ts < ADMIN_HANDSHAKE_MAX_AGE)); then
      log_info "admin device $ip: handshake $((now - ts)) s ago"
      return 0
    fi
  done < <(wg show wg0 latest-handshakes 2>/dev/null || true)
  return 1
}

close_public_ssh() {
  local current=$SSH_SERVER_PORT
  if systemctl is-active --quiet "$ROLLBACK_UNIT.timer"; then
    die "$ROLLBACK_UNIT.timer is still pending from an earlier run; wait for it or stop it first"
  fi
  # Safety net first: if closing locks the admin out, public SSH comes back by itself.
  run systemd-run --unit "$ROLLBACK_UNIT" --on-active="$ROLLBACK_DELAY" ufw allow "$SSH_PORT/tcp"
  run ufw delete allow "$SSH_PORT/tcp"
  if [[ -n $current && $current != "$SSH_PORT" ]]; then
    run ufw delete allow "$current/tcp"
  fi
  if session_over_wg; then
    # This very session runs over WireGuard: the path is proven, the safety net is not needed.
    run systemctl stop "$ROLLBACK_UNIT.timer"
    log_info "public SSH closed; SSH only from $HOMELAB_WG_NET"
  else
    log_warn "public SSH closed. Within $ROLLBACK_DELAY open a NEW session over WireGuard" \
      "(ssh -p $SSH_PORT <admin>@$WG_IP) and run: sudo systemctl stop $ROLLBACK_UNIT.timer" \
      "— otherwise public SSH is reopened automatically."
  fi
}

step 03 firewall
if admin_path_ok; then
  step 03-ssh close_public_ssh
else
  log_warn "public SSH stays open: no admin device is connected over WireGuard yet (no marker 03-ssh)." \
    "Connect an admin device to WireGuard, then run: sudo ./install.sh --step 03-ssh"
fi
