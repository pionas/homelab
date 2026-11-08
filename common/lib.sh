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
