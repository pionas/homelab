#!/usr/bin/env bash
# Step 11: k3s server on the WireGuard address, with the cluster CAs from the wizard placed before
# the first start (otherwise k3s makes its own and ArgoCD cannot connect) and RBAC for ArgoCD.
# The installer comes from a pinned k3s tag and must match its checksum; it verifies the k3s binary
# against the release checksums itself.
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

K3S_VERSION=v1.36.5+k3s1
K3S_INSTALLER_URL=https://raw.githubusercontent.com/k3s-io/k3s/v1.36.5%2Bk3s1/install.sh
K3S_INSTALLER_SHA256=46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad
K3S_TLS=$HOMELAB_K3S_DATA_DIR/server/tls
K3S_MANIFESTS=$HOMELAB_K3S_MANIFESTS
K3S_CONFIG=/etc/rancher/k3s/config.yaml
K3S_POD_NET=10.42.0.0/16
K3S_SERVICE_NET=10.43.0.0/16
# CA files k3s takes from server/tls on its first start (docs.k3s.io/cli/certificate).
K3S_CA_FILES=(server-ca.crt server-ca.key client-ca.crt client-ca.key request-header-ca.crt
  request-header-ca.key etcd/peer-ca.crt etcd/peer-ca.key etcd/server-ca.crt etcd/server-ca.key service.key)
K3S_READY_TIMEOUT=120
# The edge runs Traefik standalone on 80/443, so the k3s one would clash.
EDGE_IP=${HOMELAB_WG_NET%.*}.100

k3s_ca() {
  local src=$HOMELAB_NODE_DIR/k3s-ca/$NODE_NAME f
  for f in "${K3S_CA_FILES[@]}"; do
    [[ -r $src/$f ]] || die "missing $src/$f: regenerate the package with the wizard"
  done
  if [[ -e $K3S_TLS/server-ca.crt ]]; then
    if cmp -s "$src/server-ca.crt" "$K3S_TLS/server-ca.crt" && cmp -s "$src/client-ca.crt" "$K3S_TLS/client-ca.crt"; then
      log_info "k3s already uses the cluster CAs from the package"
      return 0
    fi
    die "k3s already has other CAs in $K3S_TLS; refusing to overwrite them (ArgoCD would lose the" \
      "cluster). Rotate with 'k3s certificate rotate-ca' instead."
  fi
  run install -d -m 700 "$K3S_TLS" "$K3S_TLS/etcd"
  for f in "${K3S_CA_FILES[@]}"; do
    if [[ $f == *.key ]]; then
      run install -m 600 "$src/$f" "$K3S_TLS/$f"
    else
      run install -m 644 "$src/$f" "$K3S_TLS/$f"
    fi
  done
}

k3s_config() {
  {
    cat <<EOF
# Managed by homelab (common/11-k3s.sh).
node-ip: $WG_IP
advertise-address: $WG_IP
tls-san:
  - $WG_IP
cluster-cidr: $K3S_POD_NET
service-cidr: $K3S_SERVICE_NET
write-kubeconfig-mode: "0600"
EOF
    if [[ $WG_IP == "$EDGE_IP" ]]; then printf 'disable:\n  - traefik\n'; fi
  } | write_file "$K3S_CONFIG"
  run install -d -m 700 "$K3S_MANIFESTS"
  run install -m 600 "$HOMELAB_COMMON_DIR/argocd-rbac.yaml" "$K3S_MANIFESTS/homelab-argocd-rbac.yaml"
}

k3s_install() {
  local installer=$HOMELAB_STATE_DIR/k3s-install-$K3S_VERSION.sh
  run install -d -m 700 "$HOMELAB_STATE_DIR"
  fetch "$K3S_INSTALLER_URL" "$installer"
  verify_sha256 "$installer" "$K3S_INSTALLER_SHA256"
  if in_container; then
    container_skip "running the k3s installer (k3s needs a privileged container); CAs, config and checksum done"
    run rm -f "$installer"
    return 0
  fi
  run env INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC=server sh "$installer"
  run rm -f "$installer"
  ((DRY_RUN)) && return 0
  local waited=0
  until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do
    ((waited < K3S_READY_TIMEOUT)) || die "k3s API not ready after $K3S_READY_TIMEOUT s: journalctl -u k3s"
    sleep 2
    waited=$((waited + 2))
  done
  cmp -s "$HOMELAB_NODE_DIR/k3s-ca/$NODE_NAME/server-ca.crt" "$K3S_TLS/server-ca.crt" ||
    die "k3s did not take the cluster CA from the package"
  log_info "k3s $K3S_VERSION ready on $WG_IP"
}

k3s_setup() {
  k3s_ca
  k3s_config
  k3s_install
}

if [[ $RUNTIME != k3s ]]; then
  log_info "step 11: $NODE_NAME runs compose, skipping k3s"
  exit 0
fi
step 11 k3s_setup
