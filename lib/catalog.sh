#!/usr/bin/env bash
# shellcheck shell=bash
# Service catalog: load and validate catalog/*/service.conf, then filter and order services.
# All state lives in _CATALOG (id,KEY -> value) and _CATALOG_IDS; functions print one id per line.

# shellcheck source=common/lib.sh
source "${BASH_SOURCE[0]%/*}/../common/lib.sh"

_CATALOG_KEYS=(ID NAME SCOPE RUNTIMES PLACEMENT PRIORITY REQUIRES SECRETS USES_SECRETS PORTS PUBLIC_PORTS AUTO_ADD)
_CATALOG_REQUIRED=(ID NAME SCOPE RUNTIMES PRIORITY)
# KEY=value or KEY="value"; no $, backticks or backslashes, so nothing can expand.
# shellcheck disable=SC2016 # literal regex, nothing to expand
_CATALOG_LINE_RE='^([A-Z_]+)=("([^"$`\\]*)"|([^"$`\\[:space:]#]*))[[:space:]]*(#.*)?$'

declare -gA _CATALOG=()
declare -ga _CATALOG_IDS=()

_catalog_has() { [[ -n ${_CATALOG["$1,ID"]+set} ]]; }

_catalog_check_ids() {
  local id rc=0
  for id in "$@"; do
    _catalog_has "$id" || {
      log_error "unknown service: $id"
      rc=1
    }
  done
  return "$rc"
}

_catalog_parse_conf() {
  local conf=$1 key=$2 line n=0 rc=0
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if ! [[ $line =~ $_CATALOG_LINE_RE ]]; then
      log_error "$conf:$n: expected KEY=value or KEY=\"value\" without \$, \` or \\"
      rc=1
      continue
    fi
    local k=${BASH_REMATCH[1]} v
    if [[ ${BASH_REMATCH[2]} == \"* ]]; then v=${BASH_REMATCH[3]}; else v=${BASH_REMATCH[4]}; fi
    if [[ " ${_CATALOG_KEYS[*]} " != *" $k "* ]]; then
      log_error "$conf:$n: unknown key $k"
      rc=1
    elif [[ -n ${seen[$k]-} ]]; then
      log_error "$conf:$n: duplicate key $k"
      rc=1
    fi
    seen[$k]=1
    _CATALOG["$key,$k"]=$v
  done <"$conf"
  return "$rc"
}

_catalog_validate() {
  local id=$1 conf=$2 rc=0 k word
  _catalog_err() {
    log_error "$conf: $*"
    rc=1
  }
  for k in "${_CATALOG_REQUIRED[@]}"; do
    [[ -n ${_CATALOG["$id,$k"]} ]] || _catalog_err "missing required key $k"
  done
  [[ ${_CATALOG["$id,ID"]} == "$id" ]] || _catalog_err "ID '${_CATALOG["$id,ID"]}' must match directory name '$id'"
  [[ $id =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || _catalog_err "ID must be lowercase [a-z0-9-]: $id"
  [[ ${_CATALOG["$id,SCOPE"]} =~ ^(always|single|multi|auto)$ ]] || _catalog_err "SCOPE must be always|single|multi|auto"
  for word in ${_CATALOG["$id,RUNTIMES"]}; do
    [[ $word =~ ^(compose|k3s)$ ]] || _catalog_err "RUNTIMES: unknown runtime $word"
  done
  [[ ${_CATALOG["$id,PLACEMENT"]} =~ ^(edge)?$ ]] || _catalog_err "PLACEMENT must be empty or edge"
  # 01-11 belong to common/ install steps.
  if ! [[ ${_CATALOG["$id,PRIORITY"]} =~ ^[0-9]{2}$ ]] || ((10#${_CATALOG["$id,PRIORITY"]} < 12)); then
    _catalog_err "PRIORITY must be a two-digit number 12-99"
  fi
  if [[ $id == *-exporter && ${_CATALOG["$id,PRIORITY"]} != 39 ]]; then
    _catalog_err "exporters must have PRIORITY=39 (after data services, before edge)"
  fi
  for k in PORTS PUBLIC_PORTS; do
    for word in ${_CATALOG["$id,$k"]}; do
      if ! [[ $word =~ ^[0-9]+$ ]] || ((word < 1 || word > 65535)); then
        _catalog_err "$k: invalid port $word"
      fi
    done
  done
  # Only the edge is exposed to the internet; everything else binds to the WG address.
  if [[ -n ${_CATALOG["$id,PUBLIC_PORTS"]} && ${_CATALOG["$id,PLACEMENT"]} != edge ]]; then
    _catalog_err "PUBLIC_PORTS is allowed only with PLACEMENT=edge"
  fi
  for word in ${_CATALOG["$id,SECRETS"]}; do
    [[ $word =~ ^[A-Z][A-Z0-9_]*$ ]] || _catalog_err "SECRETS: invalid role $word"
  done
  for word in ${_CATALOG["$id,USES_SECRETS"]}; do
    [[ $word =~ ^[A-Z][A-Z0-9_]*:[A-Z][A-Z0-9_]*$ ]] || _catalog_err "USES_SECRETS: expected PREFIX:ROLE, got $word"
  done
  return "$rc"
}

# Cross-service checks, run once every service is parsed.
_catalog_validate_refs() {
  local id word owner rc=0
  for id in "${_CATALOG_IDS[@]}"; do
    for word in ${_CATALOG["$id,REQUIRES"]}; do
      _catalog_has "$word" || {
        log_error "$id: REQUIRES unknown service $word"
        rc=1
      }
    done
    for word in ${_CATALOG["$id,AUTO_ADD"]}; do
      if ! _catalog_has "$word"; then
        log_error "$id: AUTO_ADD unknown service $word"
        rc=1
      elif [[ ${_CATALOG["$word,SCOPE"]} != auto ]]; then
        log_error "$id: AUTO_ADD target $word must have SCOPE=auto"
        rc=1
      fi
    done
    for word in ${_CATALOG["$id,USES_SECRETS"]}; do
      owner=${word%%:*}
      owner=${owner,,}
      owner=${owner//_/-}
      _catalog_has "$owner" || {
        log_error "$id: USES_SECRETS $word refers to unknown service $owner"
        rc=1
      }
    done
  done
  return "$rc"
}

# catalog_load DIR — loads DIR/*/service.conf; logs every error and returns 1 if any.
catalog_load() {
  local dir=$1 conf id k rc=0
  _CATALOG=()
  _CATALOG_IDS=()
  [[ -d $dir ]] || {
    log_error "catalog directory not found: $dir"
    return 1
  }
  for conf in "$dir"/*/service.conf; do
    [[ -e $conf ]] || continue
    id=${conf%/service.conf}
    id=${id##*/}
    for k in "${_CATALOG_KEYS[@]}"; do _CATALOG["$id,$k"]=''; done
    _catalog_parse_conf "$conf" "$id" || rc=1
    _catalog_validate "$id" "$conf" || rc=1
    _CATALOG_IDS+=("$id")
  done
  ((${#_CATALOG_IDS[@]})) || {
    log_error "no services found in $dir"
    return 1
  }
  _catalog_validate_refs || rc=1
  return "$rc"
}

catalog_ids() { printf '%s\n' "${_CATALOG_IDS[@]}"; }

catalog_get() {
  _catalog_check_ids "$1" || return 1
  printf '%s\n' "${_CATALOG["$1,$2"]}"
}

# Machine runtime -> service runtimes it can host (k3s machines also get Docker for compose).
_catalog_fits_runtime() {
  local id=$1 machine_runtime=$2 r
  for r in ${_CATALOG["$id,RUNTIMES"]}; do
    [[ $r == compose || $machine_runtime == k3s ]] && return 0
  done
  return 1
}

_catalog_check_machine() {
  [[ $1 =~ ^(compose|k3s)$ ]] || {
    log_error "machine runtime must be compose or k3s, got: $1"
    return 1
  }
  [[ $2 =~ ^[01]$ ]] || {
    log_error "is_edge must be 0 or 1, got: $2"
    return 1
  }
}

# catalog_forced RUNTIME IS_EDGE — services the machine always gets (shown locked).
catalog_forced() {
  local runtime=$1 is_edge=$2 id out=()
  _catalog_check_machine "$runtime" "$is_edge" || return 1
  for id in "${_CATALOG_IDS[@]}"; do
    _catalog_fits_runtime "$id" "$runtime" || continue
    if [[ ${_CATALOG["$id,SCOPE"]} == always ]] ||
      [[ ${_CATALOG["$id,PLACEMENT"]} == edge && $is_edge == 1 ]]; then
      out+=("$id")
    fi
  done
  ((${#out[@]})) || return 0
  catalog_sort "${out[@]}"
}

# catalog_selectable RUNTIME IS_EDGE [ASSIGNED_ID...] — optional services offered for a machine.
# ASSIGNED_ID: services already placed on earlier machines (single ones are hidden).
catalog_selectable() {
  local runtime=$1 is_edge=$2 id out=()
  shift 2
  _catalog_check_machine "$runtime" "$is_edge" || return 1
  _catalog_check_ids "$@" || return 1
  local assigned=" $* "
  for id in "${_CATALOG_IDS[@]}"; do
    [[ ${_CATALOG["$id,SCOPE"]} =~ ^(always|auto)$ ]] && continue
    [[ -n ${_CATALOG["$id,PLACEMENT"]} ]] && continue
    [[ ${_CATALOG["$id,SCOPE"]} == single && $assigned == *" $id "* ]] && continue
    _catalog_fits_runtime "$id" "$runtime" || continue
    out+=("$id")
  done
  ((${#out[@]})) || return 0
  catalog_sort "${out[@]}"
}

# catalog_expand ID... — adds AUTO_ADD services recursively, without duplicates.
catalog_expand() {
  _catalog_check_ids "$@" || return 1
  local -a queue=("$@") out=()
  local -A seen=()
  local id
  while ((${#queue[@]})); do
    id=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -n ${seen[$id]-} ]] && continue
    seen[$id]=1
    out+=("$id")
    # shellcheck disable=SC2206 # AUTO_ADD is a validated space-separated id list
    queue+=(${_CATALOG["$id,AUTO_ADD"]})
  done
  ((${#out[@]})) || return 0
  printf '%s\n' "${out[@]}"
}

# catalog_missing_requires ID... — prints "ID REQUIRED" for every unmet REQUIRES; returns 1 if any.
catalog_missing_requires() {
  _catalog_check_ids "$@" || return 1
  local selected=" $* " id req rc=0
  for id in "$@"; do
    for req in ${_CATALOG["$id,REQUIRES"]}; do
      [[ $selected == *" $req "* ]] && continue
      printf '%s %s\n' "$id" "$req"
      rc=1
    done
  done
  return "$rc"
}

# catalog_sort ID... — orders by PRIORITY, then by id.
catalog_sort() {
  _catalog_check_ids "$@" || return 1
  (($#)) || return 0
  local id
  for id in "$@"; do printf '%s %s\n' "${_CATALOG["$id,PRIORITY"]}" "$id"; done |
    sort -k1,1n -k2,2 | cut -d' ' -f2
}
