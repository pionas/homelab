#!/usr/bin/env bash
# Service mariadb (priority 31): under Docker, published on the WireGuard address; DEFAULT and
# VIEWER accounts created on the first start. Runs from the package: <machine>/services/mariadb/.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=mariadb
DATA_DIR=/var/lib/homelab/data/$SERVICE_ID

install_mariadb() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  install_service_files "$SERVICE_ID" docker-compose.yml mariadb.env initdb/10-homelab-viewer.sh
  # The image's entrypoint takes ownership of an empty data directory itself.
  run install -d -m 700 "$DATA_DIR"
  compose_up "$SERVICE_ID"
  log_info "MariaDB on $WG_IP:3306 (data in $DATA_DIR; accounts are created on the first start only)"
}

step "31-$SERVICE_ID" install_mariadb
