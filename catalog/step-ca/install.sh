#!/usr/bin/env bash
# Service step-ca (priority 21): CA server with the wizard's intermediate CA (from the package of
# this machine only), an ACME provisioner, and a JWK provisioner for the admin protected by
# STEP_CA_DEFAULT_PASSWORD. Runs from the package: <machine>/services/step-ca/install.sh.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env
load_env "$HOMELAB_NODE_DIR/secrets.env" '[A-Z][A-Z0-9_]*_(USERNAME|PASSWORD)' STEP_CA_DEFAULT_USERNAME STEP_CA_DEFAULT_PASSWORD

SERVICE_ID=step-ca
COMPOSE_DIR=$HOMELAB_COMPOSE_ROOT/$SERVICE_ID
STEP_HOME=$COMPOSE_DIR/step
# The step user in the smallstep/step-ca image.
STEP_UID=1000
CA_SRC=$HOMELAB_NODE_DIR/ca

install_step_ca() {
  local runtime f
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  [[ $STEP_CA_DEFAULT_USERNAME =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "STEP_CA_DEFAULT_USERNAME must be a plain name"
  for f in "$CA_SRC/intermediate_ca.crt" "$CA_SRC/intermediate_ca.key" "$HOMELAB_COMMON_DIR/root_ca.crt" \
    "$SERVICE_DIR/ca.json" "$SERVICE_DIR/docker-compose.yml"; do
    [[ -r $f ]] || die "missing $f: only the step-ca machine's package has the intermediate CA"
  done
  run install -d -m 755 "$COMPOSE_DIR"
  run install -d -m 700 -o "$STEP_UID" -g "$STEP_UID" "$STEP_HOME" "$STEP_HOME/config" "$STEP_HOME/certs" \
    "$STEP_HOME/secrets" "$STEP_HOME/db"
  run install -m 644 "$SERVICE_DIR/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
  run install -m 644 -o "$STEP_UID" -g "$STEP_UID" "$HOMELAB_COMMON_DIR/root_ca.crt" "$STEP_HOME/certs/root_ca.crt"
  run install -m 644 -o "$STEP_UID" -g "$STEP_UID" "$CA_SRC/intermediate_ca.crt" "$STEP_HOME/certs/intermediate_ca.crt"
  run install -m 600 -o "$STEP_UID" -g "$STEP_UID" "$CA_SRC/intermediate_ca.key" "$STEP_HOME/secrets/intermediate_ca.key"
  # Rewritten on every install from the package; the JWK provisioner is added to it again below.
  run install -m 600 -o "$STEP_UID" -g "$STEP_UID" "$SERVICE_DIR/ca.json" "$STEP_HOME/config/ca.json"
  printf '%s' "$STEP_CA_DEFAULT_PASSWORD" | write_file "$STEP_HOME/secrets/provisioner_password" 600
  run chown "$STEP_UID:$STEP_UID" "$STEP_HOME/secrets/provisioner_password"
  if in_container; then
    container_skip "adding the JWK provisioner and starting step-ca (no dockerd in the container)"
    return 0
  fi
  run docker compose -f "$COMPOSE_DIR/docker-compose.yml" run --rm --no-deps --entrypoint step "$SERVICE_ID" \
    ca provisioner add "$STEP_CA_DEFAULT_USERNAME" --type JWK --create \
    --password-file /home/step/secrets/provisioner_password --ca-config /home/step/config/ca.json
  compose_up "$SERVICE_ID"
  log_info "step-ca on https://ca.$DOMAIN:9000 ($WG_IP), ACME provisioner 'acme'"
}

step "21-$SERVICE_ID" install_step_ca
