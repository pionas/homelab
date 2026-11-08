#!/usr/bin/env bash
# Step 02: WireGuard interface wg0 from the package's wg0.conf. Re-run with --force after the
# wizard added a machine (new peers); a running tunnel is updated live, without dropping it.
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

WG_CONF=/etc/wireguard/wg0.conf

wireguard_setup() {
  local src=$HOMELAB_NODE_DIR/wg0.conf
  [[ -r $src ]] || die "missing $src"
  grep -qx "ListenPort = $WG_PORT" "$src" ||
    die "$src does not listen on WG_PORT=$WG_PORT from node.env: regenerate the package with the wizard"
  write_file "$WG_CONF" 600 <"$src"
  if systemctl is-active --quiet wg-quick@wg0; then
    # syncconf applies peer changes in place; a restart would cut sessions running over the tunnel.
    run bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
  else
    run systemctl enable --now wg-quick@wg0
  fi
}

# Never fails: peers appear only as the other machines get installed.
wireguard_check() {
  local ts total=0 silent=0
  if ! wg show wg0 latest-handshakes >/dev/null 2>&1; then
    log_warn "wg0 is not up yet (expected with --dry-run before the first install)"
    return 0
  fi
  while IFS=$'\t' read -r _ ts; do
    total=$((total + 1))
    if ((ts == 0)); then silent=$((silent + 1)); fi
  done < <(wg show wg0 latest-handshakes)
  if ((silent)); then
    log_warn "$silent of $total WireGuard peers have no handshake yet (normal until they are installed)"
  else
    log_info "all $total WireGuard peers have a handshake"
  fi
}

step 02 wireguard_setup
wireguard_check
