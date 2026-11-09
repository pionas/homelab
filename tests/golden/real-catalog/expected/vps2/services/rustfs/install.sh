#!/usr/bin/env bash
# Service rustfs (priority 32): S3 object storage under Docker, API and console on the WireGuard
# address. Runs from the package: <machine>/services/rustfs/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=rustfs
DATA_ROOT=/var/lib/homelab/data/$SERVICE_ID
# The rustfs user in the rustfs/rustfs image; every mounted path must be writable by it.
RUSTFS_UID=10001

install_rustfs() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  install_service_files "$SERVICE_ID" docker-compose.yml rustfs.env
  run install -d -m 700 -o "$RUSTFS_UID" -g "$RUSTFS_UID" "$DATA_ROOT" "$DATA_ROOT/data" "$DATA_ROOT/logs"
  compose_up "$SERVICE_ID"
  log_info "RustFS S3 API on $WG_IP:9000, console on $WG_IP:9001 (data in $DATA_ROOT/data)"
}

step "32-$SERVICE_ID" install_rustfs
