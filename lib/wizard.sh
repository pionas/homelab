#!/usr/bin/env bash
# shellcheck shell=bash
# Wizard flow: asks the questions (lib/ui.sh), builds the state (lib/state.sh), validates the plan
# (lib/validate.sh) and generates secrets, WireGuard, CA files and packages (lib/render.sh) into OUT_DIR.

_WIZARD_LIB=${BASH_SOURCE[0]%/*}
# shellcheck source=lib/ui.sh
source "$_WIZARD_LIB/ui.sh"
# shellcheck source=lib/validate.sh
source "$_WIZARD_LIB/validate.sh"
# shellcheck source=lib/secrets.sh
source "$_WIZARD_LIB/secrets.sh"
# shellcheck source=lib/wg.sh
source "$_WIZARD_LIB/wg.sh"
# shellcheck source=lib/ca.sh
source "$_WIZARD_LIB/ca.sh"
# shellcheck source=lib/render.sh
source "$_WIZARD_LIB/render.sh"

WIZARD_TOOLS=(yq wg openssl qrencode step ssh-keygen perl)

declare -g WIZARD_EXISTING=0

wizard_check_tools() {
  local tool rc=0
  for tool in "${WIZARD_TOOLS[@]}"; do
    type -P "$tool" >/dev/null || {
      log_error "missing tool: $tool (see docs/jak-pracowac.md, section 4)"
      rc=1
    }
  done
  return "$rc"
}

# _wizard_machine N — asks about machine N (1 = edge) and adds it to the state.
_wizard_machine() {
  local n=$1 p="M$1_" name endpoint wg_port ssh_port os runtime is_edge=0 def_name=vps$(($1 - 1))
  ((n == 1)) && is_edge=1 def_name=edge
  ui_input "${p}NAME" "Machine $n: name" "$def_name" || return 1
  name=$UI_ANSWER
  ui_input "${p}ENDPOINT" "$name: address it is reachable at (IP or hostname, WireGuard Endpoint)" || return 1
  endpoint=$UI_ANSWER
  # The edge port is the default everywhere: a VPS may expose only a few ports, or one.
  wg_port=$STATE_DEFAULT_WG_PORT
  ((n == 1)) || wg_port=$(state_query '.machines[0].wg_port')
  ui_input "${p}WG_PORT" "$name: WireGuard port (UDP); the provider must let it through" "$wg_port" || return 1
  wg_port=$UI_ANSWER
  ui_input "${p}SSH_PORT" "$name: SSH port" "$STATE_DEFAULT_SSH_PORT" || return 1
  ssh_port=$UI_ANSWER
  ui_menu "${p}OS" "$name: operating system" debian debian ubuntu || return 1
  os=$UI_ANSWER
  ui_yesno "${p}ARGOCD" "$name: runs ArgoCD or applications deployed by ArgoCD? (requires k3s)" no || return 1
  if [[ $UI_ANSWER == yes ]]; then
    runtime=k3s
  else
    ui_menu "${p}RUNTIME" "$name: runtime" "$(state_query .default_runtime)" compose k3s || return 1
    runtime=$UI_ANSWER
  fi
  state_add_machine "$name" "$endpoint" "$os" "$runtime" "$wg_port" "$ssh_port" || return 1

  local -a forced selectable assigned chosen
  mapfile -t forced < <(catalog_forced "$runtime" "$is_edge")
  mapfile -t assigned < <(state_query '.machines[].services[]')
  mapfile -t selectable < <(catalog_selectable "$runtime" "$is_edge" "${assigned[@]}")
  # Forced services are accepted in the answer too (e.g. traefik on the edge) and always added.
  ui_checklist "${p}SERVICES" "$name: services (always installed: ${forced[*]:-none})" \
    "${selectable[@]}" "${forced[@]}" || return 1
  # shellcheck disable=SC2206 # validated service ids
  chosen=("${forced[@]}" $UI_ANSWER)
  ((${#chosen[@]})) || return 0
  # shellcheck disable=SC2046 # validated service ids, one per line
  state_set_services "$name" $(catalog_sort $(printf '%s\n' "${chosen[@]}" | sort -u))
  _wizard_ports "$n" "$name"
}

# _wizard_ports N NAME — optional moved host ports, e.g. when everything runs on one server.
_wizard_ports() {
  local p="M$1_" name=$2 entry hint='' id port
  local -a ids=()
  mapfile -t ids < <(N=$name state_query '.machines[] | select(.name == strenv(N)) | .services[]')
  if ((${#ids[@]})); then
    for id in $(catalog_expand "${ids[@]}"); do
      for port in $(catalog_get "$id" PORTS) $(catalog_get "$id" PUBLIC_PORTS); do hint+=" $id:$port"; done
    done
  fi
  ui_input "${p}PORTS" "$name: move host ports as service:port=new_port, space-separated (none = defaults;${hint:- no ports})" none || return 1
  [[ $UI_ANSWER == none ]] && return 0
  for entry in $UI_ANSWER; do
    if ! [[ $entry =~ ^([a-z0-9]+(-[a-z0-9]+)*):([0-9]+)=([0-9]+)$ ]]; then
      log_error "${p}PORTS: expected service:port=new_port, got: $entry"
      return 1
    fi
    state_set_port_override "$name" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" || return 1
  done
}

_wizard_devices() {
  local entry name type
  ui_input DEVICES "Admin devices as name:type, space-separated (types: windows ios android linux)" || return 1
  for entry in $UI_ANSWER; do
    [[ $entry == *:* ]] || {
      log_error "DEVICES: expected name:type, got: $entry"
      return 1
    }
    name=${entry%%:*} type=${entry#*:}
    # Re-running with the same answers keeps existing devices.
    [[ -n $(N=$name state_query '.admin_devices[] | select(.name == strenv(N)) | .name') ]] && continue
    state_add_device "$name" "$type" || return 1
  done
}

# _wizard_routes — public routes through the edge (Traefik), asked after the machines exist.
_wizard_routes() {
  local entry host machine fallback extra
  ui_input ROUTES "Public routes through the edge as host:machine[:fallback_machine], space-separated (none = no routes)" none || return 1
  [[ $UI_ANSWER == none ]] && return 0
  for entry in $UI_ANSWER; do
    IFS=: read -r host machine fallback extra <<<"$entry"
    if [[ -z $host || -z $machine || -n $extra ]]; then
      log_error "ROUTES: expected host:machine[:fallback_machine], got: $entry"
      return 1
    fi
    # Re-running with the same answers keeps existing routes.
    [[ -n $(H=$host state_query '(.routes // [])[] | select(.host == strenv(H)) | .host') ]] && continue
    state_add_route "$host" "$machine" "$fallback" || return 1
  done
}

# _wizard_argocd_host — the ArgoCD UI address, asked only when ArgoCD is placed.
_wizard_argocd_host() {
  [[ -n $(state_query '[.machines[] | select(.services[] == "argocd")][0] // ""') ]] || return 0
  ui_input ARGOCD_HOST "ArgoCD UI address (VPN only); another domain must resolve to the ArgoCD machine" \
    "$(state_argocd_host)" || return 1
  state_set_argocd_host "$UI_ANSWER"
}

# wizard_collect OUT_DIR GITOPS_REPO — loads OUT_DIR/state.yaml when present (existing machines and
# their addresses stay as they are) and asks only about what is new.
wizard_collect() {
  local out_dir=$1 repo=$2 total n
  if [[ -e $out_dir/state.yaml ]]; then
    state_load "$out_dir/state.yaml" || return 1
    WIZARD_EXISTING=$(state_query '.machines | length')
    if [[ -n $repo && $repo != "$(state_query .gitops_repo)" ]]; then
      log_error "--gitops-repo differs from gitops_repo in $out_dir/state.yaml"
      return 1
    fi
    log_info "loaded $out_dir/state.yaml with $WIZARD_EXISTING machine(s); asking only about new ones"
  else
    [[ -n $repo ]] || {
      log_error "--gitops-repo is required for a new state"
      return 1
    }
    ui_menu DEFAULT_RUNTIME "Default runtime for machines" compose compose k3s || return 1
    state_init "$repo" "$UI_ANSWER"
  fi
  ui_input MACHINES "Number of machines (1 = everything on the edge)" "$((WIZARD_EXISTING > 0 ? WIZARD_EXISTING : 1))" || return 1
  total=$UI_ANSWER
  if ! [[ $total =~ ^[0-9]+$ ]] || ((total < 1 || total < WIZARD_EXISTING)); then
    log_error "MACHINES must be a number >= $((WIZARD_EXISTING > 0 ? WIZARD_EXISTING : 1)), got: $total"
    return 1
  fi
  _wizard_devices || return 1
  for ((n = WIZARD_EXISTING + 1; n <= total; n++)); do
    _wizard_machine "$n" || return 1
  done
  _wizard_routes || return 1
  _wizard_argocd_host || return 1
  local unused
  unused=$(ui_unused_answers)
  [[ -z $unused ]] || {
    log_error "answers not used by any question (typo?): ${unused//$'\n'/ }"
    return 1
  }
}

# wizard_generate OUT_DIR — validates the plan, then writes secrets, WireGuard, CA and state.yaml.
wizard_generate() {
  local out_dir=$1 name
  validate_plan || return 1
  (umask 077 && mkdir -p "$out_dir") || return 1
  secrets_generate "$out_dir" || return 1
  wg_ensure_keys "$out_dir" || return 1
  ca_ensure_root "$out_dir" && ca_ensure_intermediate "$out_dir" || return 1
  if [[ -n $(state_query '[.machines[] | select(.services[] == "argocd")][0] // ""') ]]; then
    gitops_ensure_deploy_key "$out_dir" || return 1
  fi
  while IFS= read -r name; do
    secrets_for_machine "$out_dir" "$name" && wg_render_machine "$out_dir" "$name" || return 1
  done < <(state_query '.machines[].name')
  while IFS= read -r name; do
    ca_ensure_k3s_cluster "$out_dir" "$name" || return 1
  done < <(state_query '.machines[] | select(.runtime == "k3s") | .name')
  while IFS= read -r name; do
    wg_render_device "$out_dir" "$name" || return 1
  done < <(state_query '.admin_devices[].name')
  render_all "$out_dir" || return 1
  state_save "$out_dir/state.yaml" || return 1
  if ((WIZARD_EXISTING)); then
    log_info "new peers added: re-run install step 02 (WireGuard) on: $(state_query '.machines[].name' |
      head -n "$WIZARD_EXISTING" | tr '\n' ' ')"
  fi
  log_info "done: packages and $out_dir/INSTALL_ORDER.md"
}
