#!/usr/bin/env bash
# Service mysqld-exporter (priority 39, added with mariadb): metrics on the WireGuard address with
# the VIEWER account. Runs from the package: <machine>/services/mysqld-exporter/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=mysqld-exporter

install_mysqld_exporter() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  install_service_files "$SERVICE_ID" docker-compose.yml mysqld-exporter.env
  compose_up "$SERVICE_ID"
  log_info "mysqld_exporter on $WG_IP:9104"
}

step "39-$SERVICE_ID" install_mysqld_exporter
