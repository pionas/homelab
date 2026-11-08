#!/usr/bin/env bash
# shellcheck shell=bash
# Service secrets: OUT/secrets.env with every account of every service in the state, and
# OUT/<machine>/secrets.env with only what that machine's services need.
# Needs a loaded catalog (catalog_load) and state (state_load). Never logs secret values.

# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

SECRETS_GENERATOR=${SECRETS_GENERATOR:-secrets_random}
# Values end up in files that may be sourced or used as env_file, so only plain characters are allowed.
_SECRETS_LINE_RE='^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._-]+)$'
_SECRETS_VALUE_RE='^[A-Za-z0-9._-]+$'

declare -gA _SECRETS=()

secrets_random() { openssl rand -base64 32 | tr -d '/+=\n'; }

# secrets_prefix ID — postgres-exporter -> POSTGRES_EXPORTER
secrets_prefix() {
  local p=${1^^}
  printf '%s\n' "${p//-/_}"
}

# DEFAULT is a reserved word in PostgreSQL (CREATE ROLE default fails), so that account is "app".
_secrets_username() {
  if [[ $1 == DEFAULT ]]; then echo app; else echo "${1,,}"; fi
}

# _secrets_read FILE — loads FILE into _SECRETS (missing file = no secrets yet).
_secrets_read() {
  local file=$1 line n=0 rc=0
  _SECRETS=()
  [[ -e $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line =~ $_SECRETS_LINE_RE ]]; then
      _SECRETS[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    else
      log_error "$file:$n: expected NAME=value with [A-Za-z0-9._-] only" # the line itself may hold a secret
      rc=1
    fi
  done <"$file"
  return "$rc"
}

# _secrets_write FILE NAME... — writes the named _SECRETS sorted, mode 600, atomically.
_secrets_write() {
  local file=$1 tmp name
  shift
  (
    umask 077
    mkdir -p "${file%/*}"
    tmp=$(mktemp "$file.XXXXXX")
    for name in "$@"; do printf '%s=%s\n' "$name" "${_SECRETS[$name]}"; done | sort >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
  )
}

# _secrets_names ID... — variable names the services own (SECRETS) and use (USES_SECRETS).
_secrets_names() {
  local id prefix role use
  for id in "$@"; do
    prefix=$(secrets_prefix "$id")
    for role in $(catalog_get "$id" SECRETS); do
      printf '%s_%s_USERNAME\n%s_%s_PASSWORD\n' "$prefix" "$role" "$prefix" "$role"
    done
    for use in $(catalog_get "$id" USES_SECRETS); do
      printf '%s_%s_USERNAME\n%s_%s_PASSWORD\n' "${use%%:*}" "${use#*:}" "${use%%:*}" "${use#*:}"
    done
  done | sort -u
}

# _secrets_state_services [MACHINE] — services of one machine or of all machines, with AUTO_ADD.
_secrets_state_services() {
  local -a ids
  if (($#)); then
    mapfile -t ids < <(N=$1 state_query '.machines[] | select(.name == strenv(N)) | .services[]')
  else
    mapfile -t ids < <(state_query '.machines[].services[]' | sort -u)
  fi
  ((${#ids[@]})) || return 0
  catalog_expand "${ids[@]}"
}

# secrets_generate OUT_DIR — adds missing secrets to OUT_DIR/secrets.env; existing values never change.
secrets_generate() {
  local file=$1/secrets.env name role value list
  local -a names=()
  _secrets_read "$file" || return 1
  list=$(_secrets_state_services) || return 1
  # shellcheck disable=SC2086 # service ids are validated [a-z0-9-] words
  [[ -n $list ]] && mapfile -t names < <(_secrets_names $list)
  for name in "${names[@]}"; do
    [[ -n ${_SECRETS[$name]-} ]] && continue
    if [[ $name == *_USERNAME ]]; then
      role=${name%_USERNAME}
      value=$(_secrets_username "${role##*_}")
    else
      value=$("$SECRETS_GENERATOR") || {
        log_error "password generator $SECRETS_GENERATOR failed"
        return 1
      }
    fi
    [[ $value =~ $_SECRETS_VALUE_RE ]] || {
      log_error "generated value for $name is empty or has characters outside [A-Za-z0-9._-]"
      return 1
    }
    _SECRETS[$name]=$value
  done
  # Keeps secrets of services no longer in the state, so re-adding a service reuses its password.
  ((${#_SECRETS[@]})) || return 0
  _secrets_write "$file" "${!_SECRETS[@]}"
}

# secrets_for_machine OUT_DIR NAME — writes OUT_DIR/NAME/secrets.env from OUT_DIR/secrets.env.
secrets_for_machine() {
  local out_dir=$1 machine=$2 name list rc=0
  local -a names=()
  [[ $(N=$machine state_query '[.machines[] | select(.name == strenv(N))] | length') == 1 ]] || {
    log_error "unknown machine: $machine"
    return 1
  }
  _secrets_read "$out_dir/secrets.env" || return 1
  list=$(_secrets_state_services "$machine") || return 1
  # shellcheck disable=SC2086 # service ids are validated [a-z0-9-] words
  [[ -n $list ]] && mapfile -t names < <(_secrets_names $list)
  for name in "${names[@]}"; do
    [[ -n ${_SECRETS[$name]-} ]] || {
      log_error "$machine: $name missing in $out_dir/secrets.env (run secrets_generate first)"
      rc=1
    }
  done
  ((rc == 0)) || return 1
  _secrets_write "$out_dir/$machine/secrets.env" "${names[@]}"
}
