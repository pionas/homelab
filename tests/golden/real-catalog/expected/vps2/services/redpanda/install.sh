#!/usr/bin/env bash
# Service redpanda (priority 34): single broker under Docker, SASL/SCRAM with the ROOT account as
# superuser, listening only on the WireGuard address. Runs from the package:
# <machine>/services/redpanda/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=redpanda
COMPOSE_DIR=$HOMELAB_COMPOSE_ROOT/$SERVICE_ID
DATA_DIR=/var/lib/homelab/data/$SERVICE_ID
# The redpanda user in the redpandadata/redpanda image; it rewrites redpanda.yaml on start.
REDPANDA_UID=101

install_redpanda() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  grep -qx 'enable_sasl: true' "$SERVICE_DIR/bootstrap.yaml" 2>/dev/null ||
    die "$SERVICE_DIR/bootstrap.yaml missing or without SASL: regenerate the package"
  install_service_files "$SERVICE_ID" docker-compose.yml redpanda.env
  run install -d -m 700 -o "$REDPANDA_UID" -g "$REDPANDA_UID" "$COMPOSE_DIR/config" "$DATA_DIR"
  run install -m 644 -o "$REDPANDA_UID" -g "$REDPANDA_UID" "$SERVICE_DIR/redpanda.yaml" "$COMPOSE_DIR/config/redpanda.yaml"
  # Read only on the first start of the cluster; later changes go through rpk cluster config.
  run install -m 644 -o "$REDPANDA_UID" -g "$REDPANDA_UID" "$SERVICE_DIR/bootstrap.yaml" "$COMPOSE_DIR/config/.bootstrap.yaml"
  compose_up "$SERVICE_ID"
  log_info "Redpanda Kafka API on $WG_IP:$(service_port redpanda 9092) (SASL/SCRAM-SHA-256), Schema Registry on $WG_IP:$(service_port redpanda 8081)"
}

step "34-$SERVICE_ID" install_redpanda
