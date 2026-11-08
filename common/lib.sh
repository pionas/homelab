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

# Consumes --dry-run / --force; anything else is an error.
parse_common_args() {
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

# load_env FILE [REQUIRED_VAR...] — exports every variable from FILE.
load_env() {
  local file=$1
  shift
  [[ -r $file ]] || die "env file not readable: $file"
  if [[ ${file##*/} == *secrets* ]]; then
    local mode
    mode=$(stat -c %a "$file")
    [[ $mode == 600 || $mode == 400 ]] || log_warn "$file has mode $mode, expected 600"
  fi
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
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

# load_node_env — node.env of this machine with every variable the common steps need.
load_node_env() {
  [[ -n ${HOMELAB_NODE_DIR:-} ]] || die "HOMELAB_NODE_DIR is not set; run the step through the machine's install.sh"
  load_env "$HOMELAB_NODE_DIR/node.env" NODE_NAME WG_IP WG_PORT SSH_PORT RUNTIME OS
  local p
  for p in WG_PORT SSH_PORT; do
    if ! [[ ${!p} =~ ^[0-9]+$ ]] || ((${!p} < 1 || ${!p} > 65535)); then
      die "$p in node.env must be a port 1-65535, got: ${!p}"
    fi
  done
}
