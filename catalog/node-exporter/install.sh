#!/usr/bin/env bash
# Service node-exporter (priority 12, every machine): under Docker on compose machines, as a k3s
# manifest on k3s machines. Runs from the package: <machine>/services/node-exporter/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=node-exporter
COMPOSE_DIR=/opt/homelab/$SERVICE_ID

install_compose() {
  run install -d -m 700 "$COMPOSE_DIR"
  run install -m 600 "$SERVICE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
  if in_container; then container_skip "docker compose up (no dockerd in the container)"; else
    run docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d
  fi
}

install_k3s() {
  run install -d -m 700 "$HOMELAB_K3S_MANIFESTS"
  run install -m 600 "$SERVICE_DIR/$SERVICE_ID.yaml" "$HOMELAB_K3S_MANIFESTS/homelab-$SERVICE_ID.yaml"
}

install_node_exporter() {
  if [[ " ${COMPOSE_SERVICES:-} " == *" $SERVICE_ID "* ]]; then
    install_compose
  elif [[ $RUNTIME == k3s ]]; then
    install_k3s
  else
    die "$SERVICE_ID is neither in COMPOSE_SERVICES nor on a k3s machine: regenerate the package"
  fi
  log_info "node_exporter on $WG_IP:9100 (WireGuard only)"
}

step "12-$SERVICE_ID" install_node_exporter
