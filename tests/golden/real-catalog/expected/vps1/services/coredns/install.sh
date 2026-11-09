#!/usr/bin/env bash
# Service coredns (priority 20): internal DNS on the WireGuard address, under Docker.
# Runs from the package: <machine>/services/coredns/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=coredns
COMPOSE_DIR=$HOMELAB_COMPOSE_ROOT/$SERVICE_ID

install_coredns() {
  local runtime f
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  run install -d -m 755 "$COMPOSE_DIR"
  # No secrets here: the zone lists WireGuard addresses only.
  for f in docker-compose.yml Corefile "db.$DOMAIN"; do
    [[ -r $SERVICE_DIR/$f ]] || die "missing $SERVICE_DIR/$f: regenerate the package"
    run install -m 644 "$SERVICE_DIR/$f" "$COMPOSE_DIR/$f"
  done
  compose_up "$SERVICE_ID"
  log_info "CoreDNS for $DOMAIN on $WG_IP:53"
}

step "20-$SERVICE_ID" install_coredns
