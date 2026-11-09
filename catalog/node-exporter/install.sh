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
COMPOSE_DIR=$HOMELAB_COMPOSE_ROOT/$SERVICE_ID

install_compose() {
  run install -d -m 700 "$COMPOSE_DIR"
  run install -m 600 "$SERVICE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
  compose_up "$SERVICE_ID"
}

install_k3s() {
  run install -d -m 700 "$HOMELAB_K3S_MANIFESTS"
  run install -m 600 "$SERVICE_DIR/$SERVICE_ID.yaml" "$HOMELAB_K3S_MANIFESTS/homelab-$SERVICE_ID.yaml"
}

install_node_exporter() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  if [[ $runtime == compose ]]; then install_compose; else install_k3s; fi
  log_info "node_exporter on $WG_IP:9100 (WireGuard only)"
}

step "12-$SERVICE_ID" install_node_exporter
