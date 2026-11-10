#!/usr/bin/env bash
# Installed to /usr/local/sbin/homelab-openbao-unseal and run by homelab-openbao-unseal.service after
# Docker starts: waits for the OpenBao API (the container restarts sealed) and unseals it with the
# key from the init file. The key goes to OpenBao on stdin, never as an argument.
set -Eeuo pipefail

CONTAINER=homelab-openbao
STATE_DIR=${HOMELAB_STATE_DIR:-/var/lib/homelab}
[[ $STATE_DIR == /* && $STATE_DIR != *..* ]] || {
  echo "homelab-openbao-unseal: HOMELAB_STATE_DIR must be an absolute path without .." >&2
  exit 1
}
INIT_FILE=$STATE_DIR/openbao/init.json
WAIT_SECONDS=180

status() { docker exec "$CONTAINER" bao status -format=json 2>/dev/null || true; }

[[ -r $INIT_FILE ]] || {
  echo "homelab-openbao-unseal: $INIT_FILE missing, nothing to unseal with" >&2
  exit 1
}
key=$(sed -n '/"unseal_keys_b64"/{n;s/^[[:space:]]*"\([^"]*\)".*/\1/p;q}' "$INIT_FILE")
[[ $key =~ ^[A-Za-z0-9+/]+=*$ ]] || {
  echo "homelab-openbao-unseal: no unseal key in $INIT_FILE" >&2
  exit 1
}

deadline=$((SECONDS + WAIT_SECONDS))
until status | grep -q '"initialized"'; do
  ((SECONDS < deadline)) || {
    echo "homelab-openbao-unseal: OpenBao API not reachable after ${WAIT_SECONDS}s" >&2
    exit 1
  }
  sleep 2
done
if status | grep -Eq '"sealed": *false'; then
  echo "homelab-openbao-unseal: already unsealed"
  exit 0
fi
printf '{"key":"%s"}' "$key" | docker exec -i "$CONTAINER" bao write -format=json sys/unseal - >/dev/null
status | grep -Eq '"sealed": *false' || {
  echo "homelab-openbao-unseal: still sealed after unseal" >&2
  exit 1
}
echo "homelab-openbao-unseal: unsealed"
