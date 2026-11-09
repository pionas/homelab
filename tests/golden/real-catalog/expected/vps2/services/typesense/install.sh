#!/usr/bin/env bash
# Service typesense (priority 35): search under Docker, published on the WireGuard address, admin
# API key from typesense.env. Runs from the package: <machine>/services/typesense/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=typesense
DATA_DIR=/var/lib/homelab/data/$SERVICE_ID
# The unprivileged user the container runs as (docker-compose.yml `user:`).
TYPESENSE_UID=10000

install_typesense() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  install_service_files "$SERVICE_ID" docker-compose.yml typesense.env
  run install -d -m 700 -o "$TYPESENSE_UID" -g "$TYPESENSE_UID" "$DATA_DIR"
  compose_up "$SERVICE_ID"
  log_info "Typesense on $WG_IP:$(service_port typesense 8108) (data in $DATA_DIR)"
}

step "35-$SERVICE_ID" install_typesense
