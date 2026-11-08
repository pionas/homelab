#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for install steps and the wizard. Source it, do not execute it.
# The caller sets `set -Eeuo pipefail`; this file only defines functions and defaults.

HOMELAB_STATE_DIR="${HOMELAB_STATE_DIR:-/var/lib/homelab}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
LOG_LEVEL="${LOG_LEVEL:-info}"

declare -gA _LOG_LEVELS=([debug]=0 [info]=1 [warn]=2 [error]=3)
declare -gA _LOG_COLORS=([debug]=$'\e[2m' [info]=$'\e[32m' [warn]=$'\e[33m' [error]=$'\e[31m')

_log() {
  local level=$1
  shift
  local threshold=${_LOG_LEVELS[$LOG_LEVEL]:-1}
  ((${_LOG_LEVELS[$level]} >= threshold)) || return 0
  local color='' reset=''
  if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
    color=${_LOG_COLORS[$level]}
    reset=$'\e[0m'
  fi
  printf '%s%s [%s] %s%s\n' "$color" "$(date '+%F %T')" "${level^^}" "$*" "$reset" >&2
}

log_debug() { _log debug "$@"; }
log_info() { _log info "$@"; }
log_warn() { _log warn "$@"; }
log_error() { _log error "$@"; }

die() {
  log_error "$@"
  exit 1
}

# Consumes --dry-run / --force; anything else (also positional arguments) is an error.
parse_common_args() {
  check_flags
  while (($#)); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --force) FORCE=1 ;;
      *) die "unknown argument: $1 (allowed: --dry-run, --force)" ;;
    esac
    shift
  done
}

# Runs a system-changing command, or only prints it with --dry-run.
run() {
  if ((DRY_RUN)); then
    local cmd
    printf -v cmd '%q ' "$@"
    printf '[dry-run] %s\n' "${cmd% }"
  else
    "$@"
  fi
}

_step_marker() { printf '%s/done/%s' "$HOMELAB_STATE_DIR" "$1"; }

step_is_done() { [[ -e $(_step_marker "$1") ]]; }

step_mark_done() {
  ((DRY_RUN)) && return 0
  mkdir -p "$HOMELAB_STATE_DIR/done"
  touch "$(_step_marker "$1")"
}

# step ID FUNCTION — runs FUNCTION once; a marker skips it later unless --force.
# ID: NN for common/ steps, NN-id for services (e.g. 30-postgresql).
step() {
  local id=$1 fn=$2
  [[ $id =~ ^[0-9]{2}(-[a-z0-9]+(-[a-z0-9]+)*)?$ ]] || die "step id must be NN or NN-id, got: $id"
  if step_is_done "$id" && ! ((FORCE)); then
    log_info "step $id ($fn) already done, skipping (use --force to rerun)"
    return 0
  fi
  log_info "step $id: $fn"
  "$fn"
  step_mark_done "$id"
}

require_root() {
  ((EUID == 0)) && return 0
  if ((DRY_RUN)); then
    log_warn "not running as root; continuing because of --dry-run"
    return 0
  fi
  die "must be run as root: sudo $0"
}

# load_env FILE ALLOWED_KEYS [REQUIRED_VAR...] — exports the variables of FILE.
# The file is parsed, never sourced (steps run as root): only KEY=value or KEY="value" lines
# without $, backticks or backslashes, and only keys matching the extended regex ALLOWED_KEYS
# (anchored), so a package can never set PATH, LD_PRELOAD, IFS or similar.
# shellcheck disable=SC2016 # literal regex, nothing to expand
_ENV_LINE_RE='^([A-Z][A-Z0-9_]*)=("([^"$`\\]*)"|([^"$`\\[:space:]#]*))$'
load_env() {
  local file=$1 allowed=$2 line key value n=0 rc=0
  shift 2
  [[ -r $file ]] || die "env file not readable: $file"
  if [[ ${file##*/} == *secrets* ]]; then
    local mode
    mode=$(stat -c %a "$file")
    [[ $mode == 600 || $mode == 400 ]] || log_warn "$file has mode $mode, expected 600"
  fi
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if ! [[ $line =~ $_ENV_LINE_RE ]]; then
      log_error "$file:$n: expected KEY=value or KEY=\"value\" without \$, \` or \\" # value may be a secret
      rc=1
      continue
    fi
    key=${BASH_REMATCH[1]}
    if [[ ${BASH_REMATCH[2]} == \"* ]]; then value=${BASH_REMATCH[3]}; else value=${BASH_REMATCH[4]}; fi
    if ! [[ $key =~ ^($allowed)$ ]]; then
      log_error "$file:$n: key $key is not allowed here"
      rc=1
    elif [[ -n ${seen[$key]-} ]]; then
      log_error "$file:$n: duplicate key $key"
      rc=1
    else
      seen[$key]=1
      printf -v "$key" '%s' "$value"
      export "${key?}"
    fi
  done <"$file"
  ((rc == 0)) || die "invalid env file: $file"
  local var
  for var in "$@"; do
    [[ -n ${!var:-} ]] || die "required variable $var is missing in $file"
  done
}

# write_file PATH [MODE] — writes stdin to PATH atomically (default mode 644). With --dry-run it
# only prints what it would write; content of mode-600 files (keys, secrets) is never printed.
write_file() {
  local path=$1 mode=${2:-644} content
  content=$(cat)
  if ((DRY_RUN)); then
    printf '[dry-run] write %s (mode %s)\n' "$path" "$mode"
    if [[ $mode == 600 || $mode == 400 ]]; then
      printf '[dry-run]   (content hidden)\n'
    else
      printf '%s\n' "$content" | sed 's/^/[dry-run]   /'
    fi
    return 0
  fi
  mkdir -p "${path%/*}"
  local tmp
  tmp=$(mktemp "$path.XXXXXX")
  printf '%s\n' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

# Package layout: common/ (this file, steps, root_ca.crt) and the machine directory exported by
# the generated install.sh as HOMELAB_NODE_DIR (node.env, secrets.env, wg0.conf).
# shellcheck disable=SC2034 # used by the install steps that source this file
HOMELAB_COMMON_DIR=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
# The WireGuard network every machine and admin device is on.
# shellcheck disable=SC2034 # used by the install steps that source this file
HOMELAB_WG_NET=10.100.10.0/24

_NODE_ENV_KEYS='NODE_NAME|WG_IP|WG_PORT|SSH_PORT|RUNTIME|OS|SERVICES|COMPOSE_SERVICES|PORTS|PUBLIC_PORTS'

_valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)); }

# load_node_env — node.env of this machine; every value is checked before any step uses it.
load_node_env() {
  [[ -n ${HOMELAB_NODE_DIR:-} ]] || die "HOMELAB_NODE_DIR is not set; run the step through the machine's install.sh"
  load_env "$HOMELAB_NODE_DIR/node.env" "$_NODE_ENV_KEYS" NODE_NAME WG_IP WG_PORT SSH_PORT RUNTIME OS
  local p rc=0 bad
  _node_bad() {
    log_error "node.env: $*"
    rc=1
  }
  [[ $NODE_NAME =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || _node_bad "NODE_NAME must be lowercase [a-z0-9-], got: $NODE_NAME"
  local octet=${WG_IP#"${HOMELAB_WG_NET%.*}".}
  if ! [[ $WG_IP == "${HOMELAB_WG_NET%.*}".* && $octet =~ ^[1-9][0-9]{0,2}$ ]] || ((octet > 254)); then
    _node_bad "WG_IP must be in $HOMELAB_WG_NET, got: $WG_IP"
  fi
  for p in WG_PORT SSH_PORT; do
    _valid_port "${!p}" || _node_bad "$p must be a port 1-65535, got: ${!p}"
  done
  [[ $RUNTIME =~ ^(compose|k3s)$ ]] || _node_bad "RUNTIME must be compose or k3s, got: $RUNTIME"
  [[ $OS =~ ^(debian|ubuntu)$ ]] || _node_bad "OS must be debian or ubuntu, got: $OS"
  for p in SERVICES COMPOSE_SERVICES; do
    [[ ${!p:-} =~ ^([a-z0-9]+(-[a-z0-9]+)*( |$))*$ ]] || _node_bad "$p must be service ids, got: ${!p}"
  done
  for bad in ${COMPOSE_SERVICES:-}; do
    [[ " ${SERVICES:-} " == *" $bad "* ]] || _node_bad "COMPOSE_SERVICES has $bad, which is not in SERVICES"
  done
  for p in PORTS PUBLIC_PORTS; do
    for bad in ${!p:-}; do
      _valid_port "$bad" || _node_bad "$p must list ports 1-65535, got: $bad"
    done
  done
  ((rc == 0)) || die "invalid $HOMELAB_NODE_DIR/node.env: regenerate the package with the wizard"
}

# shellcheck disable=SC2034 # SSH_CLIENT_IP and SSH_SERVER_PORT are read by the steps
# ssh_session — parses $SSH_CONNECTION ("client_ip client_port server_ip server_port") into
# SSH_CLIENT_IP and SSH_SERVER_PORT; both stay empty outside SSH or when the value is malformed.
ssh_session() {
  SSH_CLIENT_IP='' SSH_SERVER_PORT=''
  [[ -n ${SSH_CONNECTION:-} ]] || return 0
  local -a f
  read -r -a f <<<"$SSH_CONNECTION"
  if ((${#f[@]} == 4)) && [[ ${f[0]} =~ ^[0-9A-Fa-f.:]{2,45}$ ]] && _valid_port "${f[1]}" && _valid_port "${f[3]}"; then
    SSH_CLIENT_IP=${f[0]} SSH_SERVER_PORT=${f[3]}
  else
    log_warn "ignoring malformed SSH_CONNECTION"
  fi
}

HOMELAB_OS_RELEASE=${HOMELAB_OS_RELEASE:-/etc/os-release}

# os_release_value KEY — one field of os-release (ID, VERSION_CODENAME); the file is read, not
# sourced, and only plain values [a-z0-9._-] are returned (empty otherwise).
os_release_value() {
  [[ $1 =~ ^[A-Z_]+$ ]] || die "os_release_value: bad key $1"
  sed -n "s/^$1=\"\{0,1\}\([a-z0-9._-]*\)\"\{0,1\}\$/\1/p" "$HOMELAB_OS_RELEASE" 2>/dev/null | head -n1
}

# fetch URL DEST — downloads over HTTPS only (TLS 1.2+, no redirects to other schemes).
fetch() {
  [[ $1 == https://* ]] || die "fetch: only https URLs, got: $1"
  run curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 -o "$2" "$1"
}

# verify_sha256 FILE SHA256 — dies unless FILE has exactly this checksum.
verify_sha256() {
  if ((DRY_RUN)); then
    printf '[dry-run] verify sha256 %s = %s\n' "$1" "$2"
    return 0
  fi
  local got
  got=$(sha256sum "$1" | cut -d' ' -f1)
  [[ $got == "$2" ]] || die "checksum mismatch for $1: expected $2, got $got (download tampered or changed)"
}

# verify_gpg_fingerprint FILE FINGERPRINT — dies unless FILE is exactly the key with this fingerprint.
verify_gpg_fingerprint() {
  if ((DRY_RUN)); then
    printf '[dry-run] verify gpg fingerprint %s = %s\n' "$1" "$2"
    return 0
  fi
  local home fprs
  home=$(mktemp -d)
  fprs=$(gpg --homedir "$home" --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "fpr" {print $10}')
  rm -rf "$home"
  [[ $fprs == "$2" ]] || die "unexpected key in $1: expected only $2, got: ${fprs:-none}"
}

# check_flags — the shared settings a caller may pass in the environment must be plain values.
check_flags() {
  [[ $DRY_RUN =~ ^[01]$ && $FORCE =~ ^[01]$ ]] || die "DRY_RUN and FORCE must be 0 or 1"
  [[ -n ${_LOG_LEVELS[$LOG_LEVEL]+set} ]] || die "LOG_LEVEL must be debug, info, warn or error"
  [[ $HOMELAB_STATE_DIR == /* && $HOMELAB_STATE_DIR != *..* ]] || die "HOMELAB_STATE_DIR must be an absolute path without .."
}
