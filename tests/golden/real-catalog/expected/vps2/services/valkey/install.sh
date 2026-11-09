#!/usr/bin/env bash
# Service valkey (priority 33): under Docker, published on the WireGuard address, ACL users from
# users.acl (password hashes). Runs from the package: <machine>/services/valkey/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=valkey
DATA_DIR=/var/lib/homelab/data/$SERVICE_ID
# The valkey user in the valkey/valkey image (the server drops to it before reading the ACL file).
VALKEY_UID=999

install_valkey() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  grep -qx 'user default off' "$SERVICE_DIR/users.acl" 2>/dev/null ||
    die "$SERVICE_DIR/users.acl missing or the default user is not off: regenerate the package"
  install_service_files "$SERVICE_ID" docker-compose.yml valkey.conf users.acl
  # Password hashes (copied with mode 600): readable only by the server.
  run chown "$VALKEY_UID:$VALKEY_UID" "$HOMELAB_COMPOSE_ROOT/$SERVICE_ID/users.acl"
  run install -d -m 700 "$DATA_DIR"
  compose_up "$SERVICE_ID"
  log_info "Valkey on $WG_IP:6379 (ACL users only, data in $DATA_DIR)"
}

step "33-$SERVICE_ID" install_valkey
