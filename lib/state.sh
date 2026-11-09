#!/usr/bin/env bash
# shellcheck shell=bash
# Wizard state (out/state.yaml): load/save, WG address allocation, adding machines and devices, validation.
# The state lives in _STATE as YAML text and is changed only through yq (mikefarah); values from
# callers reach yq via environment variables, never by splicing them into the expression.

# shellcheck source=lib/catalog.sh
source "${BASH_SOURCE[0]%/*}/catalog.sh"

STATE_WG_NET=10.100.10
STATE_EDGE_IP=$STATE_WG_NET.100
STATE_DEFAULT_WG_PORT=51820
STATE_DEFAULT_SSH_PORT=22
# Field separator for yq rows: not whitespace, so bash `read` keeps empty fields.
_STATE_FS=$'\x1f'
# Every row starts with this marker: yq prints a blank line for an empty list, which must not count as a row.
_STATE_ROW=row
# Names become directory and key file names, so they must be safe path components.
_STATE_NAME_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
# Internal DNS zone (CoreDNS): every machine name, plus these names -> the machine of the service.
# shellcheck disable=SC2034 # used by lib/render.sh and lib/validate.sh
STATE_DOMAIN=homelab.internal
# shellcheck disable=SC2034
STATE_DNS_NAMES="argo:argocd grafana:argocd bao:openbao valkey:valkey redpanda:redpanda ca:step-ca s3:rustfs"
# A WireGuard key: 32 bytes in base64.
STATE_WG_KEY_RE='^[A-Za-z0-9+/]{43}=$'

declare -g _STATE=''

_state_yq() { yq "$@" <<<"$_STATE"; }

# state_init GITOPS_REPO DEFAULT_RUNTIME — starts an empty state.
state_init() {
  _STATE=$(REPO=$1 RT=$2 yq -n '.gitops_repo = strenv(REPO) | .default_runtime = strenv(RT) |
    .machines = [] | .admin_devices = []')
}

state_load() {
  local file=$1
  [[ -f $file ]] || {
    log_error "state file not found: $file"
    return 1
  }
  local text
  text=$(yq '.' "$file") || {
    log_error "$file: not valid YAML"
    return 1
  }
  [[ $(yq 'tag' <<<"$text") == '!!map' ]] || {
    log_error "$file: state must be a YAML mapping"
    return 1
  }
  _STATE=$text
}

state_save() { printf '%s\n' "$_STATE" >"$1"; }

# state_query YQ_EXPR — read-only access for callers and tests.
state_query() { _state_yq -r "$1"; }

# _state_first_free FROM TO EXPR — first last-octet in FROM..TO not used by the wg_ip list EXPR.
_state_first_free() {
  local from=$1 to=$2 i
  local -A used=()
  while IFS= read -r i; do [[ -n $i ]] && used[${i##*.}]=1; done < <(_state_yq -r "$3")
  for ((i = from; i <= to; i++)); do
    [[ -z ${used[$i]-} ]] && {
      printf '%s.%s\n' "$STATE_WG_NET" "$i"
      return 0
    }
  done
  log_error "no free WG address in $STATE_WG_NET.$from-$to"
  return 1
}

# The edge (machines[0]) is always .100, outside the .101-.199 pool.
state_next_machine_ip() { _state_first_free 101 199 '.machines[].wg_ip'; }
state_next_device_ip() { _state_first_free 200 254 '.admin_devices[].wg_ip'; }

# _state_try YQ_EXPR — applies the change, keeps it only if the state stays valid (no catalog check).
_state_try() {
  local before=$_STATE
  _STATE=$(_state_yq "$1") && _state_check 0 && return 0
  _STATE=$before
  return 1
}

# state_add_machine NAME ENDPOINT OS RUNTIME [WG_PORT] [SSH_PORT]
# The first machine is the edge (.100). An empty WG_PORT takes the edge's port, an empty SSH_PORT 22.
state_add_machine() {
  local ip wg_port=${5:-} ssh_port=${6:-$STATE_DEFAULT_SSH_PORT}
  if [[ $(_state_yq '.machines | length') == 0 ]]; then
    ip=$STATE_EDGE_IP
    wg_port=${wg_port:-$STATE_DEFAULT_WG_PORT}
  else
    ip=$(state_next_machine_ip) || return 1
    wg_port=${wg_port:-$(_state_yq -r '.machines[0].wg_port')}
  fi
  # Ports are added as strings when not numeric, so validation reports them instead of yq failing.
  N=$1 E=$2 O=$3 R=$4 IP=$ip WP=$wg_port SP=$ssh_port _state_try '.machines += [{
    "name": strenv(N), "endpoint": strenv(E), "os": strenv(O), "runtime": strenv(R), "wg_ip": strenv(IP),
    "wg_port": (strenv(WP) | select(test("^[0-9]+$")) | to_number) // strenv(WP),
    "ssh_port": (strenv(SP) | select(test("^[0-9]+$")) | to_number) // strenv(SP),
    "services": []}]'
}

# state_set_services NAME [SERVICE...] — replaces the machine's service list.
state_set_services() {
  local name=$1
  shift
  [[ $(N=$name _state_yq '[.machines[] | select(.name == strenv(N))] | length') == 1 ]] || {
    log_error "unknown machine: $name"
    return 1
  }
  N=$name S="$*" _state_try '(.machines[] | select(.name == strenv(N)) | .services) =
    (strenv(S) | split(" ") | map(select(. != "")))'
}

# state_add_device NAME TYPE
state_add_device() {
  local ip
  ip=$(state_next_device_ip) || return 1
  N=$1 T=$2 IP=$ip _state_try '.admin_devices += [{"name": strenv(N), "type": strenv(T), "wg_ip": strenv(IP)}]'
}

# state_set_wg_key NAME PUBLIC_KEY — sets wg_public_key of a machine or admin device.
state_set_wg_key() {
  [[ $(N=$1 _state_yq '[(.machines[], .admin_devices[]) | select(.name == strenv(N))] | length') == 1 ]] || {
    log_error "unknown machine or device: $1"
    return 1
  }
  N=$1 K=$2 _state_try '((.machines[], .admin_devices[]) | select(.name == strenv(N)) | .wg_public_key) = strenv(K)'
}

# Public routes on the edge (Traefik): an application host name served by a machine (its k3s
# ingress on the WireGuard address), optionally with a fallback machine for failover.
STATE_ROUTE_PORT=80
STATE_ROUTE_HEALTH_PATH=/healthz

# state_add_route HOST MACHINE [FALLBACK] — appends a route; a host already routed is an error.
state_add_route() {
  local fallback_field=''
  [[ -n ${3:-} ]] && fallback_field=', "fallback": strenv(F)'
  H=$1 M=$2 F=${3:-} P=$STATE_ROUTE_PORT HP=$STATE_ROUTE_HEALTH_PATH _state_try '.routes = ((.routes // []) + [
    {"host": strenv(H), "machine": strenv(M)'"$fallback_field"', "port": (strenv(P) | to_number),
     "health_path": strenv(HP)}])'
}

_state_port_ok() { [[ $1 == '!!int' && $2 =~ ^[0-9]+$ ]] && ((10#$2 >= 1 && 10#$2 <= 65535)); }

# _state_check WITH_CATALOG — logs every problem in _STATE; WITH_CATALOG=1 also checks service ids.
_state_check() {
  local with_catalog=$1 rc=0
  local -A names=() ips=()
  _state_err() {
    log_error "state: $*"
    rc=1
  }
  local repo rt
  IFS=$_STATE_FS read -r repo rt < <(_state_yq -r '[.gitops_repo // "", .default_runtime // ""] | join("'"$_STATE_FS"'")')
  [[ -n $repo ]] || _state_err "gitops_repo is empty"
  [[ $rt =~ ^(compose|k3s)$ ]] || _state_err "default_runtime must be compose or k3s, got: '$rt'"
  [[ $(_state_yq '(.machines | tag) + (.admin_devices | tag)') == '!!seq!!seq' ]] ||
    _state_err "machines and admin_devices must be lists"

  local i=0 mark name endpoint os runtime ip wpt wp spt sp svt services svc octet
  while IFS=$_STATE_FS read -r mark name endpoint os runtime ip wpt wp spt sp svt services; do
    [[ $mark == "$_STATE_ROW" ]] || continue
    local at="machine '$name'"
    [[ $name =~ $_STATE_NAME_RE ]] || _state_err "machines[$i]: name must be lowercase [a-z0-9-], got: '$name'"
    [[ -z ${names[$name]-} ]] || _state_err "duplicate name: $name"
    names[$name]=1
    [[ $endpoint =~ ^[A-Za-z0-9.:-]+$ ]] || _state_err "$at: endpoint must be an IP or hostname, got: '$endpoint'"
    [[ $os =~ ^(debian|ubuntu)$ ]] || _state_err "$at: os must be debian or ubuntu, got: '$os'"
    [[ $runtime =~ ^(compose|k3s)$ ]] || _state_err "$at: runtime must be compose or k3s, got: '$runtime'"
    _state_port_ok "$wpt" "$wp" || _state_err "$at: wg_port must be an integer 1-65535, got: '$wp'"
    _state_port_ok "$spt" "$sp" || _state_err "$at: ssh_port must be an integer 1-65535, got: '$sp'"
    octet=${ip#"$STATE_WG_NET".}
    if ((i == 0)); then
      [[ $ip == "$STATE_EDGE_IP" ]] || _state_err "$at: the edge (first machine) must have wg_ip $STATE_EDGE_IP"
    elif ! [[ $ip == "$STATE_WG_NET".* && $octet =~ ^[0-9]+$ ]] || ((10#$octet < 101 || 10#$octet > 199)); then
      _state_err "$at: wg_ip must be in $STATE_WG_NET.101-199, got: '$ip'"
    fi
    [[ -z ${ips[$ip]-} ]] || _state_err "duplicate wg_ip: $ip"
    ips[$ip]=1
    [[ $svt == '!!seq' ]] || _state_err "$at: services must be a list"
    if ((with_catalog)); then
      for svc in $services; do
        _catalog_has "$svc" || _state_err "$at: unknown service $svc"
      done
    fi
    i=$((i + 1))
  done < <(_state_yq -r '.machines[] | ["'"$_STATE_ROW"'", .name // "", .endpoint // "", .os // "", .runtime // "",
    .wg_ip // "", (.wg_port | tag), .wg_port // "", (.ssh_port | tag), .ssh_port // "",
    (.services | tag), ((.services // []) | join(" "))] | join("'"$_STATE_FS"'")' 2>/dev/null)

  local type
  while IFS=$_STATE_FS read -r mark name type ip; do
    [[ $mark == "$_STATE_ROW" ]] || continue
    [[ $name =~ $_STATE_NAME_RE ]] || _state_err "admin device name must be lowercase [a-z0-9-], got: '$name'"
    [[ -z ${names[$name]-} ]] || _state_err "duplicate name: $name"
    names[$name]=1
    [[ $type =~ ^(windows|ios|android|linux)$ ]] ||
      _state_err "device '$name': type must be windows|ios|android|linux, got: '$type'"
    octet=${ip#"$STATE_WG_NET".}
    if ! [[ $ip == "$STATE_WG_NET".* && $octet =~ ^[0-9]+$ ]] || ((10#$octet < 200 || 10#$octet > 254)); then
      _state_err "device '$name': wg_ip must be in $STATE_WG_NET.200-254, got: '$ip'"
    fi
    [[ -z ${ips[$ip]-} ]] || _state_err "duplicate wg_ip: $ip"
    ips[$ip]=1
  done < <(_state_yq -r '.admin_devices[] | ["'"$_STATE_ROW"'", .name // "", .type // "", .wg_ip // ""] | join("'"$_STATE_FS"'")' 2>/dev/null)

  _state_check_routes || rc=1

  # wg_public_key is optional (set by lib/wg.sh); when present it must be a key.
  local key
  while IFS=$_STATE_FS read -r mark name key; do
    [[ $mark == "$_STATE_ROW" ]] || continue
    [[ $key =~ $STATE_WG_KEY_RE ]] || _state_err "'$name': wg_public_key is not a WireGuard key"
  done < <(_state_yq -r '(.machines[], .admin_devices[]) | select(has("wg_public_key")) |
    ["'"$_STATE_ROW"'", .name // "", .wg_public_key // ""] | join("'"$_STATE_FS"'")' 2>/dev/null)
  return "$rc"
}

# _state_check_routes — routes[] is optional; every route must point at known, distinct machines.
_state_check_routes() {
  local rc=0 mark host machine fallback pt port path
  local -A machines=() hosts=()
  [[ $(_state_yq '(.routes // []) | tag') == '!!seq' ]] || {
    log_error "state: routes must be a list"
    return 1
  }
  while IFS= read -r machine; do [[ -n $machine ]] && machines[$machine]=1; done < <(_state_yq -r '.machines[].name' 2>/dev/null)
  while IFS=$_STATE_FS read -r mark host machine fallback pt port path; do
    [[ $mark == "$_STATE_ROW" ]] || continue
    local at="route '$host'"
    if ! [[ $host =~ ^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)+$ ]]; then
      log_error "state: route host must be a lowercase domain name, got: '$host'"
      rc=1
    fi
    [[ -z ${hosts[$host]-} ]] || {
      log_error "state: duplicate route host: $host"
      rc=1
    }
    hosts[$host]=1
    [[ -n ${machines[$machine]-} ]] || {
      log_error "state: $at: unknown machine '$machine'"
      rc=1
    }
    if [[ -n $fallback ]] && { [[ -z ${machines[$fallback]-} ]] || [[ $fallback == "$machine" ]]; }; then
      log_error "state: $at: fallback must be another known machine, got: '$fallback'"
      rc=1
    fi
    _state_port_ok "$pt" "$port" || {
      log_error "state: $at: port must be an integer 1-65535, got: '$port'"
      rc=1
    }
    [[ $path =~ ^/[A-Za-z0-9._/-]*$ ]] || {
      log_error "state: $at: health_path must be a URL path, got: '$path'"
      rc=1
    }
  done < <(_state_yq -r '(.routes // [])[] | ["'"$_STATE_ROW"'", .host // "", .machine // "", .fallback // "",
    (.port | tag), .port // "", .health_path // ""] | join("'"$_STATE_FS"'")' 2>/dev/null)
  return "$rc"
}

# state_validate FILE CATALOG_DIR — logs every error and returns 1 if any.
state_validate() {
  catalog_load "$2" || return 1
  state_load "$1" || return 1
  state_check_complete
}

# state_check_complete — the full check of a finished state: fields, services, at least the edge.
# (Adding items checks only fields, so devices can be added before the first machine.)
state_check_complete() {
  local rc=0
  _state_check 1 || rc=1
  [[ $(_state_yq '.machines | length') != 0 ]] || {
    log_error "state: no machines (the first one is the edge)"
    rc=1
  }
  return "$rc"
}
