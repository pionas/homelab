#!/usr/bin/env bash
# shellcheck shell=bash
# Whole-plan checks on the loaded state and catalog, beyond what one machine's fields can show.
# Logs every problem and returns 1 if any.

# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Infrastructure the plan cannot work without; checked only when the catalog offers the service.
VALIDATE_ALWAYS_REQUIRED=(step-ca)
VALIDATE_MULTI_MACHINE_REQUIRED=(coredns)

_validate_in_catalog() { [[ $'\n'$(catalog_ids)$'\n' == *$'\n'"$1"$'\n'* ]]; }

# _validate_machine NAME RUNTIME IS_EDGE SSH_PORT SERVICE... — runtime fit, placement, port conflicts.
_validate_machine() {
  local name=$1 runtime=$2 is_edge=$3 ssh_port=$4 id port rc=0
  shift 4
  local -A owner=([$ssh_port]="ssh")
  for id in "$@"; do
    if [[ $runtime != k3s && " $(catalog_get "$id" RUNTIMES) " != *" compose "* ]]; then
      log_error "plan: $name: $id needs k3s, machine runtime is $runtime"
      rc=1
    fi
    if [[ $(catalog_get "$id" PLACEMENT) == edge && $is_edge != 1 ]]; then
      log_error "plan: $name: $id may run only on the edge (the first machine)"
      rc=1
    fi
    # Service ports are TCP like SSH; WireGuard is UDP, so it never collides with them.
    for port in $(catalog_get "$id" PORTS) $(catalog_get "$id" PUBLIC_PORTS); do
      if [[ -n ${owner[$port]-} ]]; then
        log_error "plan: $name: port $port/tcp used by both ${owner[$port]} and $id"
        rc=1
      fi
      owner[$port]=$id
    done
  done
  return "$rc"
}

# validate_plan — run after catalog_load and with the state in place (state_load or the wizard).
validate_plan() {
  local rc=0 name runtime ssh_port services id i=0 missing
  local -a all=()
  local -A count=()
  state_check_complete || return 1
  while IFS=$'\t' read -r name runtime ssh_port services; do
    local -a ids=()
    # shellcheck disable=SC2086 # validated service ids
    [[ -n $services ]] && mapfile -t ids < <(catalog_expand $services)
    _validate_machine "$name" "$runtime" "$((i == 0))" "$ssh_port" "${ids[@]}" || rc=1
    for id in "${ids[@]}"; do count[$id]=$((${count[$id]:-0} + 1)); done
    all+=("${ids[@]}")
    i=$((i + 1))
  done < <(state_query '.machines[] | [.name, .runtime, .ssh_port, (.services | join(" "))] | @tsv')

  for id in "${!count[@]}"; do
    if [[ $(catalog_get "$id" SCOPE) == single ]] && ((count[$id] > 1)); then
      log_error "plan: $id may be placed only once, found on ${count[$id]} machines"
      rc=1
    fi
  done
  if ((${#all[@]})); then
    # shellcheck disable=SC2046 # validated service ids, one per line
    while read -r id missing; do
      log_error "plan: $id requires $missing on some machine"
      rc=1
    done < <(catalog_missing_requires $(printf '%s\n' "${all[@]}" | sort -u) || true)
  fi
  local -a required=("${VALIDATE_ALWAYS_REQUIRED[@]}")
  ((i > 1)) && required+=("${VALIDATE_MULTI_MACHINE_REQUIRED[@]}")
  for id in "${required[@]}"; do
    _validate_in_catalog "$id" || continue
    [[ -n ${count[$id]-} ]] || {
      log_error "plan: $id is required but placed on no machine"
      rc=1
    }
  done
  return "$rc"
}
