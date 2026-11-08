#!/usr/bin/env bash
# shellcheck shell=bash
# WireGuard: keys for every machine and admin device, full-mesh wg0.conf per machine and
# client configs (+ QR for phones) per admin device. Needs a loaded state (state_load).
# Private keys live only under OUT_DIR (OUT_DIR/wg/<name>.key, mode 600); public keys go to the state.

# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Injectable so golden tests get stable keys; public keys are always derived with `wg pubkey`.
WG_KEYGEN=${WG_KEYGEN:-wg_genkey}
# Admin devices sit behind NAT and change networks, so they keep the tunnel alive.
WG_DEVICE_KEEPALIVE=25

wg_genkey() { wg genkey; }

# _wg_write FILE — writes stdin to FILE atomically, readable only by the owner.
_wg_write() {
  (
    umask 077
    mkdir -p "${1%/*}"
    local tmp
    tmp=$(mktemp "$1.XXXXXX")
    cat >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$1"
  )
}

_wg_key_file() { printf '%s/wg/%s.key\n' "$1" "$2"; }

_wg_private_key() {
  local file key
  file=$(_wg_key_file "$1" "$2")
  key=$(<"$file") || return 1
  [[ $key =~ $STATE_WG_KEY_RE ]] || {
    log_error "$file: not a WireGuard private key" # never print the key itself
    return 1
  }
  printf '%s\n' "$key"
}

_wg_participants() { state_query '.machines[].name, .admin_devices[].name'; }

# wg_ensure_keys OUT_DIR — generates missing private keys, keeps existing ones,
# and stores every public key in the state (derived from the private key file).
wg_ensure_keys() {
  local out_dir=$1 name file key pub
  while IFS= read -r name; do
    file=$(_wg_key_file "$out_dir" "$name")
    if [[ ! -e $file ]]; then
      key=$("$WG_KEYGEN") || {
        log_error "key generator $WG_KEYGEN failed for $name"
        return 1
      }
      [[ $key =~ $STATE_WG_KEY_RE ]] || {
        log_error "key generator $WG_KEYGEN returned an invalid key for $name"
        return 1
      }
      printf '%s\n' "$key" | _wg_write "$file"
    fi
    key=$(_wg_private_key "$out_dir" "$name") || return 1
    pub=$(wg pubkey <<<"$key") || return 1
    state_set_wg_key "$name" "$pub" || return 1
  done < <(_wg_participants)
}

# _wg_endpoint HOST PORT — IPv6 addresses need brackets.
_wg_endpoint() {
  if [[ $1 == *:* ]]; then printf '[%s]:%s\n' "$1" "$2"; else printf '%s:%s\n' "$1" "$2"; fi
}

# _wg_check_keys — every participant must have a public key (wg_ensure_keys first).
_wg_check_keys() {
  local missing
  missing=$(state_query '(.machines[], .admin_devices[]) | select(has("wg_public_key") | not) | .name')
  [[ -z $missing ]] || {
    log_error "no WireGuard key for: ${missing//$'\n'/ } (run wg_ensure_keys first)"
    return 1
  }
}

# _wg_peers SKIP_NAME WITH_DEVICES KEEPALIVE — [Peer] blocks for all machines (with Endpoint)
# and, if WITH_DEVICES=1, admin devices (no Endpoint: they connect to us).
_wg_peers() {
  local skip=$1 with_devices=$2 keepalive=$3 name ip pub host port
  while IFS=$'\t' read -r name ip pub host port; do
    [[ $name == "$skip" ]] && continue
    printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = %s\n' \
      "$name" "$pub" "$ip" "$(_wg_endpoint "$host" "$port")"
    [[ -n $keepalive ]] && printf 'PersistentKeepalive = %s\n' "$keepalive"
  done < <(state_query '.machines[] | [.name, .wg_ip, .wg_public_key, .endpoint, .wg_port] | @tsv')
  ((with_devices)) || return 0
  while IFS=$'\t' read -r name ip pub; do
    [[ $name == "$skip" ]] && continue
    printf '\n[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$ip"
  done < <(state_query '.admin_devices[] | [.name, .wg_ip, .wg_public_key] | @tsv')
}

# wg_render_machine OUT_DIR NAME — OUT_DIR/NAME/wg0.conf: full mesh plus all admin devices.
wg_render_machine() {
  local out_dir=$1 name=$2 ip port key
  IFS=$'\t' read -r ip port < <(N=$name state_query '.machines[] | select(.name == strenv(N)) | [.wg_ip, .wg_port] | @tsv')
  [[ -n ${ip-} ]] || {
    log_error "unknown machine: $name"
    return 1
  }
  _wg_check_keys || return 1
  key=$(_wg_private_key "$out_dir" "$name") || return 1
  {
    printf '[Interface]\nAddress = %s/24\nPrivateKey = %s\nListenPort = %s\n' "$ip" "$key" "$port"
    _wg_peers "$name" 1 ''
  } | _wg_write "$out_dir/$name/wg0.conf"
}

# wg_dns_ip — WG address of the machine running coredns, or the edge when there is none.
wg_dns_ip() {
  local ip
  ip=$(state_query '[.machines[] | select(.services[] == "coredns") | .wg_ip][0] // ""')
  printf '%s\n' "${ip:-$(state_query '.machines[0].wg_ip')}"
}

# wg_render_device OUT_DIR NAME — OUT_DIR/admin-devices/NAME/NAME.conf (+ NAME.png for ios/android).
wg_render_device() {
  local out_dir=$1 name=$2 ip type key conf
  IFS=$'\t' read -r ip type < <(N=$name state_query '.admin_devices[] | select(.name == strenv(N)) | [.wg_ip, .type] | @tsv')
  [[ -n ${ip-} ]] || {
    log_error "unknown admin device: $name"
    return 1
  }
  _wg_check_keys || return 1
  key=$(_wg_private_key "$out_dir" "$name") || return 1
  conf=$out_dir/admin-devices/$name/$name.conf
  {
    printf '[Interface]\nAddress = %s/24\nPrivateKey = %s\nDNS = %s\n' "$ip" "$key" "$(wg_dns_ip)"
    _wg_peers "$name" 0 "$WG_DEVICE_KEEPALIVE"
  } | _wg_write "$conf"
  if [[ $type == ios || $type == android ]]; then
    # The QR code holds the private key too, so it gets the same permissions.
    qrencode -t png -o - <"$conf" | _wg_write "${conf%.conf}.png"
  fi
}

# wg_peers_to_update NEW — machines that must re-run install step 02 after NEW joined.
wg_peers_to_update() {
  N=$1 state_query '.machines[] | select(.name != strenv(N)) | .name'
}
