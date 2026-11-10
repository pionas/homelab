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
    local default
    for default in $(catalog_get "$id" PORTS) $(catalog_get "$id" PUBLIC_PORTS); do
      port=$(state_port "$name" "$id" "$default")
      if [[ -n ${owner[$port]-} ]]; then
        log_error "plan: $name: port $port/tcp used by both ${owner[$port]} and $id" \
          "(move one: ${id}:${default}=<free port> in this machine's port overrides, M<n>_PORTS)"
        rc=1
      fi
      owner[$port]=$id
    done
  done
  _validate_port_overrides "$name" "$@" || rc=1
  return "$rc"
}

# _validate_port_overrides NAME SERVICE... — overrides only for the machine's services and their
# ports, never for a FIXED_PORTS one.
_validate_port_overrides() {
  local name=$1 entry id default rc=0
  shift
  # shellcheck disable=SC2016 # $s is a yq variables
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    id=${entry%:*} default=${entry#*:}
    if [[ " $* " != *" $id "* ]]; then
      log_error "plan: $name: port override for $id, which is not on this machine"
      rc=1
    elif [[ " $(catalog_get "$id" PORTS) $(catalog_get "$id" PUBLIC_PORTS) " != *" $default "* ]]; then
      log_error "plan: $name: port override $id:$default, but $id uses: $(catalog_get "$id" PORTS) $(catalog_get "$id" PUBLIC_PORTS)"
      rc=1
    elif [[ " $(catalog_get "$id" FIXED_PORTS) " == *" $default "* ]]; then
      log_error "plan: $name: port $default of $id cannot be moved (clients expect it there)"
      rc=1
    fi
  done < <(N=$name state_query '.machines[] | select(.name == strenv(N)) | (.port_overrides // {}) | to_entries[] |
    .key as $s | (.value // {}) | keys[] | $s + ":" + .')
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
  # A machine named like a zone name (ns, ca, argo...) would give that name two addresses.
  local entry
  while IFS= read -r name; do
    for entry in ns $STATE_DNS_NAMES; do
      if [[ $name == "${entry%%:*}" ]]; then
        log_error "plan: machine name $name is reserved for the $STATE_DOMAIN zone"
        rc=1
      fi
    done
  done < <(state_query '.machines[].name')
  # A route host inside the zone must not take the name of a machine or panel.
  local host label
  while IFS= read -r host; do
    [[ $host == *".$STATE_DOMAIN" ]] || continue
    label=${host%".$STATE_DOMAIN"}
    if [[ -n $(N=$label state_query '.machines[] | select(.name == strenv(N)) | .name') ||
    " ns ${STATE_DNS_NAMES//:/ } " == *" $label "* ]]; then
      log_error "plan: route host $host clashes with a machine or panel name in $STATE_DOMAIN"
      rc=1
    fi
  done < <(state_query '(.routes // [])[].host')
  if [[ -n $(state_query '[.machines[] | select(.services[] == "argocd")][0] // ""') ]]; then
    local argo
    argo=$(state_argocd_host)
    if [[ -n $(H=$argo state_query '(.routes // [])[] | select(.host == strenv(H)) | .host') ]]; then
      log_error "plan: ArgoCD address $argo is also a public route (panels are VPN only)"
      rc=1
    fi
    label=${argo%".$STATE_DOMAIN"}
    if [[ $argo == *".$STATE_DOMAIN" && $label != argo ]] &&
      { [[ -n $(N=$label state_query '.machines[] | select(.name == strenv(N)) | .name') ]] ||
        [[ " ns ${STATE_DNS_NAMES//:/ } " == *" $label "* ]]; }; then
      log_error "plan: ArgoCD address $argo clashes with a machine or panel name in $STATE_DOMAIN"
      rc=1
    fi
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
