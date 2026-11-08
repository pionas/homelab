#!/usr/bin/env bash
# Step 04: trust the homelab root CA (common/root_ca.crt from the package) system-wide.
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

CA_DEST=/usr/local/share/ca-certificates/homelab-root-ca.crt
CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

ca_trust() {
  local src=$HOMELAB_COMMON_DIR/root_ca.crt
  openssl x509 -in "$src" -noout 2>/dev/null || die "$src is not a PEM certificate"
  run install -m 644 "$src" "$CA_DEST"
  run update-ca-certificates
  if ((DRY_RUN)); then
    log_info "would verify $src against $CA_BUNDLE"
  else
    openssl verify -CAfile "$CA_BUNDLE" "$src" >/dev/null || die "root CA is not trusted after update-ca-certificates"
    log_info "root CA trusted"
  fi
}

step 04 ca_trust
