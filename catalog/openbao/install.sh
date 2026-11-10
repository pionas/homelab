#!/usr/bin/env bash
# Service openbao (priority 45): secret store under Docker on the WireGuard address. Initialises it
# ONCE (a second init would lock everyone out), unseals it, loads every homelab secret into the KV
# store homelab/ and installs the auto-unseal unit. Runs from the package:
# <machine>/services/openbao/install.sh (only this machine's package has kv/*.json).
#
# Decision (#17): `bao operator init` runs on the server — OpenBao generates the root key itself, the
# wizard cannot supply one. The unseal key and root token stay on this machine in INIT_FILE (root,
# mode 600). shortcut: key and data on the same machine (VirtualBox stage); production needs a manual
# unseal or an external KMS.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=openbao
CONTAINER=homelab-openbao
DATA_DIR=/var/lib/homelab/data/$SERVICE_ID
# The unseal unit reads the same path (homelab-openbao-unseal.sh) with the default state directory.
INIT_DIR=$HOMELAB_STATE_DIR/openbao
INIT_FILE=$INIT_DIR/init.json
KV_MOUNT=homelab
UNSEAL_BIN=/usr/local/sbin/homelab-openbao-unseal
UNSEAL_UNIT=/etc/systemd/system/homelab-openbao-unseal.service
API_WAIT_SECONDS=120
# The openbao user and group in the openbao/openbao image.
BAO_UID=100
BAO_GID=1000

# bao ARGS... — the bao CLI in the container; stdin passes through, the token comes from the
# environment (BAO_TOKEN), never from the command line.
bao() { run docker exec -i -e BAO_TOKEN "$CONTAINER" bao "$@"; }

# bao_stdin ARGS... — bao with data piped in; with --dry-run nothing reads it, so it is drained here
# (otherwise the writer dies of SIGPIPE).
bao_stdin() {
  if ((DRY_RUN)); then cat >/dev/null; fi
  bao "$@"
}

# Read-only, also with --dry-run: the status JSON (`bao status` exits 2 while sealed).
bao_status() { docker exec "$CONTAINER" bao status -format=json 2>/dev/null || true; }

wait_for_api() {
  local deadline=$((SECONDS + API_WAIT_SECONDS))
  until bao_status | grep -q '"initialized"'; do
    ((SECONDS < deadline)) || die "OpenBao API not reachable after ${API_WAIT_SECONDS}s: docker logs $CONTAINER"
    sleep 2
  done
}

init_once() {
  local status
  status=$(bao_status)
  if grep -Eq '"initialized": *true' <<<"$status"; then
    [[ -r $INIT_FILE ]] || die "OpenBao is initialized but $INIT_FILE is missing: restore it (it holds the" \
      "unseal key and root token); never initialize again"
    log_info "OpenBao already initialized"
    return 0
  fi
  if ! grep -Eq '"initialized": *false' <<<"$status"; then
    ((DRY_RUN)) || die "cannot tell whether OpenBao is initialized; refusing to run operator init"
    log_warn "OpenBao status unknown (dry-run): showing what a first install does"
  fi
  [[ ! -e $INIT_FILE ]] || die "OpenBao is not initialized but $INIT_FILE exists (data lost?)." \
    "Move it away deliberately before a new init; it is the only key to the old data."
  if ((DRY_RUN)); then
    printf '[dry-run] docker exec %s bao operator init -key-shares=1 -key-threshold=1 -format=json > %s (mode 600)\n' \
      "$CONTAINER" "$INIT_FILE"
    return 0
  fi
  docker exec "$CONTAINER" bao operator init -key-shares=1 -key-threshold=1 -format=json | write_file "$INIT_FILE" 600
  log_info "OpenBao initialized; unseal key and root token in $INIT_FILE"
}

# init_value KEY — unseal key or root token from INIT_FILE (bao's pretty JSON), checked.
init_value() {
  local v
  case $1 in
    unseal) v=$(sed -n '/"unseal_keys_b64"/{n;s/^[[:space:]]*"\([^"]*\)".*/\1/p;q}' "$INIT_FILE") ;;
    token) v=$(sed -n 's/^[[:space:]]*"root_token":[[:space:]]*"\([^"]*\)".*/\1/p' "$INIT_FILE") ;;
  esac
  [[ $v =~ ^[A-Za-z0-9+/._=-]+$ ]] || die "no $1 value in $INIT_FILE"
  printf '%s' "$v"
}

unseal_and_load() {
  local f id
  if ((DRY_RUN)) && [[ ! -r $INIT_FILE ]]; then
    printf '[dry-run] unseal with the key from %s, enable kv-v2 at %s/, load %s\n' "$INIT_FILE" "$KV_MOUNT" \
      "$(cd "$SERVICE_DIR/kv" && printf '%s ' *.json)"
    return 0
  fi
  if ! bao_status | grep -Eq '"sealed": *false'; then
    printf '{"key":"%s"}' "$(init_value unseal)" | bao_stdin write -format=json sys/unseal -
  fi
  BAO_TOKEN=$(init_value token)
  export BAO_TOKEN
  if ! docker exec -e BAO_TOKEN "$CONTAINER" bao secrets list -format=json 2>/dev/null | grep -q "\"$KV_MOUNT/\""; then
    bao secrets enable -path="$KV_MOUNT" kv-v2
  fi
  for f in "$SERVICE_DIR"/kv/*.json; do
    [[ -e $f ]] || continue
    id=${f##*/}
    id=${id%.json}
    [[ $id =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "unexpected file name $f"
    bao_stdin kv put -mount="$KV_MOUNT" "$id" - <"$f"
  done
  unset BAO_TOKEN
}

install_unseal_unit() {
  run install -m 700 "$SERVICE_DIR/homelab-openbao-unseal.sh" "$UNSEAL_BIN"
  run install -m 644 "$SERVICE_DIR/homelab-openbao-unseal.service" "$UNSEAL_UNIT"
  run systemctl daemon-reload
  run systemctl enable homelab-openbao-unseal.service
}

install_openbao() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == compose ]] || die "$SERVICE_ID runs only under Docker (COMPOSE_SERVICES)"
  [[ -d $SERVICE_DIR/kv ]] || die "missing $SERVICE_DIR/kv: only the OpenBao machine's package has the secrets"
  install_service_files "$SERVICE_ID" docker-compose.yml config.hcl
  run install -d -m 700 -o "$BAO_UID" -g "$BAO_GID" "$DATA_DIR"
  run install -d -m 700 "$INIT_DIR"
  compose_up "$SERVICE_ID"
  if in_container; then
    container_skip "init, unseal and loading secrets (OpenBao does not run in the container)"
    install_unseal_unit
    return 0
  fi
  ((DRY_RUN)) || wait_for_api
  init_once
  unseal_and_load
  install_unseal_unit
  log_info "OpenBao on $WG_IP:$(service_port openbao 8200): unsealed, secrets in $KV_MOUNT/"
}

step "45-$SERVICE_ID" install_openbao
