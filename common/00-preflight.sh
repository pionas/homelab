#!/usr/bin/env bash
# Step 00: checks that this machine can be installed. Changes nothing, runs every time (no marker).
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root

OS_RELEASE=${HOMELAB_OS_RELEASE:-/etc/os-release}

preflight() {
  local rc=0 os f client server_port
  os=$(
    # shellcheck disable=SC1090 # system file with KEY=value lines
    . "$OS_RELEASE"
    echo "${ID:-}"
  )
  [[ $os == debian || $os == ubuntu ]] || {
    log_error "unsupported system '$os': Debian or Ubuntu required"
    rc=1
  }
  load_node_env
  [[ $os == "$OS" ]] || log_warn "node.env says OS=$OS but this machine runs $os"
  getent ahosts deb.debian.org >/dev/null || {
    log_error "no network or DNS: cannot resolve deb.debian.org"
    rc=1
  }
  modinfo wireguard >/dev/null 2>&1 || {
    log_error "kernel module wireguard is not available"
    rc=1
  }
  for f in "$HOMELAB_NODE_DIR/wg0.conf" "$HOMELAB_NODE_DIR/secrets.env" "$HOMELAB_COMMON_DIR/root_ca.crt"; do
    [[ -r $f ]] || {
      log_error "missing package file: $f"
      rc=1
    }
  done
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    read -r client _ _ server_port <<<"$SSH_CONNECTION"
    log_info "SSH session from $client to port $server_port"
    if [[ $server_port != "$SSH_PORT" ]]; then
      log_warn "sshd moves to port $SSH_PORT in step 01 (this session stays on $server_port):" \
        "make sure the provider lets $SSH_PORT/tcp through before continuing"
    fi
  else
    log_info "not an SSH session (local console)"
  fi
  return "$rc"
}

preflight || die "preflight failed, nothing was changed"
log_info "preflight OK for $NODE_NAME ($WG_IP)"
