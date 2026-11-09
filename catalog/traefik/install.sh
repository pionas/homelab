#!/usr/bin/env bash
# Service traefik (priority 40, edge only): public 80/443, routes from dynamic/routes.yml,
# certificates from step-ca. Runs from the package: <machine>/services/traefik/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=traefik
COMPOSE_DIR=$HOMELAB_COMPOSE_ROOT/$SERVICE_ID
ACME_STORE=$COMPOSE_DIR/acme/acme.json

install_traefik() {
  local runtime f
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  for f in docker-compose.yml traefik.yml dynamic/routes.yml; do
    [[ -r $SERVICE_DIR/$f ]] || die "missing $SERVICE_DIR/$f: regenerate the package"
  done
  grep -q 'caServer: "https://[0-9.]*:9000/' "$SERVICE_DIR/traefik.yml" ||
    die "traefik.yml has no step-ca address: the plan needs step-ca on some machine"
  run install -d -m 755 "$COMPOSE_DIR" "$COMPOSE_DIR/dynamic"
  run install -m 644 "$SERVICE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
  run install -m 644 "$SERVICE_DIR/traefik.yml" "$COMPOSE_DIR/traefik.yml"
  run install -m 644 "$SERVICE_DIR/dynamic/routes.yml" "$COMPOSE_DIR/dynamic/routes.yml"
  run install -m 644 "$HOMELAB_COMMON_DIR/root_ca.crt" "$COMPOSE_DIR/root_ca.crt"
  # Issued certificates live in acme.json: kept across reinstalls; Traefik requires mode 600.
  run install -d -m 700 "$COMPOSE_DIR/acme"
  if [[ -e $ACME_STORE ]]; then
    run chmod 600 "$ACME_STORE"
  else
    run install -m 600 /dev/null "$ACME_STORE"
  fi
  compose_up "$SERVICE_ID"
  log_info "Traefik on public 80/443 with $(grep -c 'certResolver: acme' "$SERVICE_DIR/dynamic/routes.yml" || true) route(s)"
}

step "40-$SERVICE_ID" install_traefik
