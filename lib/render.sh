#!/usr/bin/env bash
# shellcheck shell=bash
# Packages: OUT/common, OUT/<machine>/ (install.sh, node.env, services/, CA files), root CA for admin
# devices, OUT/INSTALL_ORDER.md and OUT/<machine>.tar.gz (common/ + <machine>/).
# Run after secrets, WireGuard and CA files exist (lib/wizard.sh does that). The root CA key and
# OUT/secrets.env never go into a package: only the files listed by ca_files_* are copied.

_RENDER_LIB=${BASH_SOURCE[0]%/*}
# shellcheck source=lib/ca.sh
source "$_RENDER_LIB/ca.sh"
# shellcheck source=lib/secrets.sh
source "$_RENDER_LIB/secrets.sh"
# shellcheck source=lib/gitops.sh
source "$_RENDER_LIB/gitops.sh"

# Injectable (golden tests): prints a 22-character bcrypt salt.
ARGOCD_SALT_GENERATOR=${ARGOCD_SALT_GENERATOR:-render_bcrypt_salt}
# k3s API port of every cluster (step 11; reachable from WireGuard only, step 03).
RENDER_K3S_API_PORT=6443

RENDER_COMMON_SRC=${RENDER_COMMON_SRC:-$_RENDER_LIB/../common}
# Steps inside a common/ file that --step can name; they run the file they live in.
RENDER_STEP_ALIASES='["03-ssh"]=03'
# Install steps from common/, in order (files are added by #11/#12).
RENDER_BASE_STEPS=(00-preflight 01-base 02-wireguard 03-ufw 04-ca-trust)
RENDER_DOCKER_STEP=10-docker
RENDER_K3S_STEP=11-k3s
# Runs last, after the services.
RENDER_VERIFY_STEP=90-verify
# Machines whose services all have SCOPE=always sort last in INSTALL_ORDER.md.
RENDER_NO_PRIORITY=99

# _render_services NAME — the machine's services with AUTO_ADD, by priority.
_render_services() {
  local -a ids
  mapfile -t ids < <(N=$1 state_query '.machines[] | select(.name == strenv(N)) | .services[]')
  ((${#ids[@]})) || return 0
  # shellcheck disable=SC2046 # validated service ids, one per line
  catalog_sort $(catalog_expand "${ids[@]}")
}

# _render_service_runtime ID MACHINE_RUNTIME — on a k3s machine a service runs in k3s when it can.
_render_service_runtime() {
  if [[ $2 == k3s && " $(catalog_get "$1" RUNTIMES) " == *" k3s "* ]]; then echo k3s; else echo compose; fi
}

render_common() {
  local out_dir=$1 f
  rm -rf "$out_dir/common"
  mkdir -p "$out_dir/common"
  # Steps and the manifests they install (e.g. the argocd RBAC for k3s).
  for f in "$RENDER_COMMON_SRC"/*.sh "$RENDER_COMMON_SRC"/*.yaml; do
    [[ -e $f ]] && cp -p "$f" "$out_dir/common/"
  done
  cp "$(ca_files_public "$out_dir")" "$out_dir/common/"
}

_render_node_env() {
  local out_dir=$1 name=$2 services=$3 id ports='' public='' compose='' runtime
  runtime=$(N=$name state_query '.machines[] | select(.name == strenv(N)) | .runtime')
  printf 'DOMAIN=%s\n' "$STATE_DOMAIN" >"$out_dir/$name/node.env"
  N=$name state_query '.machines[] | select(.name == strenv(N)) | ["NODE_NAME=" + .name, "WG_IP=" + .wg_ip,
    "WG_PORT=" + (.wg_port | tostring), "SSH_PORT=" + (.ssh_port | tostring), "RUNTIME=" + .runtime,
    "OS=" + .os] | .[]' >>"$out_dir/$name/node.env"
  local p
  for id in $services; do
    for p in $(catalog_get "$id" PORTS); do ports+=" $(state_port "$name" "$id" "$p")"; done
    for p in $(catalog_get "$id" PUBLIC_PORTS); do public+=" $(state_port "$name" "$id" "$p")"; done
    [[ $(_render_service_runtime "$id" "$runtime") == compose ]] && compose+=" $id"
  done
  # PORTS: reachable from the WireGuard network only; PUBLIC_PORTS: open to the internet (edge).
  # shellcheck disable=SC2086 # split the space-separated port lists
  ports=$(printf '%s\n' $ports | sort -nu | xargs)
  # shellcheck disable=SC2086
  public=$(printf '%s\n' $public | sort -nu | xargs)
  # COMPOSE_SERVICES: the ones run by Docker (step 10 is needed only when there is one).
  # PORT_OVERRIDES: id:default=port for every moved port, so the steps know where a service really is.
  # shellcheck disable=SC2016 # $s is a yq variable
  printf 'SERVICES="%s"\nCOMPOSE_SERVICES="%s"\nPORTS="%s"\nPUBLIC_PORTS="%s"\nPORT_OVERRIDES="%s"\n' \
    "$services" "${compose# }" "$ports" "$public" \
    "$(N=$name state_query '[.machines[] | select(.name == strenv(N)) | (.port_overrides // {}) | to_entries[] |
      .key as $s | (.value // {}) | to_entries[] | $s + ":" + .key + "=" + (.value | tostring)] | join(" ")')" \
    >>"$out_dir/$name/node.env"
}

# _render_templates OUT NAME ID — copies catalog/<id>/ into services/<id>/; *.tpl files are rendered
# with envsubst limited to node.env and the machine's secrets, so other $ stay untouched.
_render_templates() {
  local out_dir=$1 name=$2 id=$3 src=$_CATALOG_DIR/$3 dst=$1/$2/services/$3 f rel
  local -a vars=() subst=()
  mkdir -p "$dst"
  _secrets_read "$out_dir/$name/secrets.env" || return 1
  local line
  while IFS= read -r line; do
    line=${line/=\"/=}
    vars+=("${line%\"}")
  done <"$out_dir/$name/node.env"
  for f in "${!_SECRETS[@]}"; do vars+=("$f=${_SECRETS[$f]}"); done
  while IFS= read -r line; do vars+=("$line"); done < <(_render_computed_vars "$name" "$id")
  for f in "${vars[@]}"; do subst+=("\${${f%%=*}}"); done
  while IFS= read -r f; do
    rel=${f#"$src"/}
    [[ $rel == service.conf ]] && continue
    mkdir -p "$dst/$(dirname "$rel")"
    if [[ $rel == *.tpl ]]; then
      env "${vars[@]}" envsubst "${subst[*]}" <"$f" >"$dst/${rel%.tpl}" || return 1
    else
      # Keep the exec bit, never group/other write: these files run as root on the machine.
      cp -p "$f" "$dst/$rel" && chmod go-w "$dst/$rel"
    fi
  done < <(find "$src" -type f | sort)
}

# _render_dns_records — "name ip" for every machine and every placed panel name.
# _render_computed_vars — template variables computed from the whole state (NAME=value lines):
#   PORT_<p>          the port this service really uses on the host for its default port p
#   <PREFIX>_PORT_<p> the same for every service on this machine (an exporter reaching its database)
#   STEP_CA_IP        WireGuard address of the step-ca machine (Traefik's ACME server)
#   STEP_CA_PORT      its port (default 9000, unless moved on that machine)
#   GITOPS_REPO       the homelab-gitops repository (state.yaml, validated SSH URL)
#   ARGOCD_HOST       the ArgoCD UI address (default argo.<domain>)
#   OPENBAO_URL       http://<OpenBao machine WG address>:<port> for External Secrets
#   ACME_EXTRA_HOSTS  route hosts -> the edge, as a YAML flow list for step-ca's extra_hosts, so the
#                     HTTP-01 check reaches Traefik without depending on CoreDNS
_render_computed_vars() {
  local name=$1 id=$2 edge svc p ca_machine
  edge=$(state_query '.machines[0].wg_ip')
  for p in $(catalog_get "$id" PORTS) $(catalog_get "$id" PUBLIC_PORTS); do
    printf 'PORT_%s=%s\n' "$p" "$(state_port "$name" "$id" "$p")"
  done
  for svc in $(_render_services "$name"); do
    for p in $(catalog_get "$svc" PORTS) $(catalog_get "$svc" PUBLIC_PORTS); do
      printf '%s_PORT_%s=%s\n' "$(secrets_prefix "$svc")" "$p" "$(state_port "$name" "$svc" "$p")"
    done
  done
  ca_machine=$(state_query '[.machines[] | select(.services[] == "step-ca") | .name][0] // ""')
  printf 'STEP_CA_IP=%s\n' "$(state_query '[.machines[] | select(.services[] == "step-ca") | .wg_ip][0] // ""')"
  printf 'STEP_CA_PORT=%s\n' "$([[ -n $ca_machine ]] && state_port "$ca_machine" step-ca 9000)"
  printf 'GITOPS_REPO=%s\n' "$(state_query '.gitops_repo')"
  local bao_machine
  bao_machine=$(state_query '[.machines[] | select(.services[] == "openbao") | .name][0] // ""')
  if [[ -n $bao_machine ]]; then
    printf 'OPENBAO_URL=http://%s:%s\n' "$(N=$bao_machine state_query '.machines[] | select(.name == strenv(N)) | .wg_ip')" \
      "$(state_port "$bao_machine" openbao 8200)"
  else
    printf 'OPENBAO_URL=\n'
  fi
  local argo_ip hosts
  hosts=$(E=$edge state_query '[(.routes // [])[] | "\"" + .host + ":" + strenv(E) + "\""] | join(", ")')
  # The ArgoCD UI is served by the ArgoCD machine's own k3s Traefik, so its HTTP-01 check goes there.
  argo_ip=$(state_query '[.machines[] | select(.services[] == "argocd") | .wg_ip][0] // ""')
  if [[ -n $argo_ip ]]; then hosts+="${hosts:+, }\"$(state_argocd_host):$argo_ip\""; fi
  printf 'ACME_EXTRA_HOSTS=[%s]\n' "$hosts"
  printf 'ARGOCD_HOST=%s\n' "$(state_argocd_host)"
}

_render_dns_records() {
  local entry ip
  state_query '.machines[] | .name + " " + .wg_ip'
  for entry in $STATE_DNS_NAMES; do
    ip=$(S=${entry#*:} state_query '[.machines[] | select(.services[] == strenv(S)) | .wg_ip][0] // ""')
    [[ -n $ip ]] && printf '%s %s\n' "${entry%%:*}" "$ip"
  done
  # A custom ArgoCD address inside the zone (argo. is already a panel name).
  local argo
  argo=$(state_argocd_host)
  ip=$(state_query '[.machines[] | select(.services[] == "argocd") | .wg_ip][0] // ""')
  if [[ -n $ip && $argo == *".$STATE_DOMAIN" && ${argo%".$STATE_DOMAIN"} != argo ]]; then
    printf '%s %s\n' "${argo%".$STATE_DOMAIN"}" "$ip"
  fi
  # Application hosts in the zone point at the edge, which routes them.
  # shellcheck disable=SC2016 # $edge is a yq variable
  D=.$STATE_DOMAIN state_query '.machines[0].wg_ip as $edge | (.routes // [])[] | select(.host | test("\\" + strenv(D) + "$")) |
    (.host | sub("\\" + strenv(D) + "$"; "")) + " " + $edge'
  return 0
}

# render_traefik_routes — Traefik dynamic configuration (file provider) for every route: TLS from
# the ACME resolver, a health-checked backend on the machine's WireGuard address and, with a
# fallback machine, a failover service (it only switches when the health check fails).
render_traefik_routes() {
  local host machine fallback port path id
  printf '# Generated by the wizard from state.yaml (routes). Panels are not routed here: VPN only.\nhttp:\n'
  if [[ $(state_query '(.routes // []) | length') == 0 ]]; then
    printf '  routers: {}\n  services: {}\n'
    return 0
  fi
  printf '  routers:\n'
  while IFS=$'\t' read -r host machine fallback port path; do
    id=${host//./_}
    # shellcheck disable=SC2016 # backticks belong to Traefik's rule syntax
    printf '    %s:\n      rule: "Host(`%s`)"\n      entryPoints: [websecure]\n      service: %s\n' "$id" "$host" "$id"
    printf '      tls:\n        certResolver: acme\n'
  done < <(_render_routes)
  printf '  services:\n'
  while IFS=$'\t' read -r host machine fallback port path; do
    id=${host//./_}
    if [[ $fallback != - ]]; then
      printf '    %s:\n      failover:\n        service: %s-main\n        fallback: %s-fallback\n' "$id" "$id" "$id"
      _render_traefik_backend "$id-main" "$machine" "$port" "$path"
      _render_traefik_backend "$id-fallback" "$fallback" "$port" "$path"
    else
      _render_traefik_backend "$id" "$machine" "$port" "$path"
    fi
  done < <(_render_routes)
}

# _render_routes — host, machine IP, fallback IP (- if none), port, health path; tab-separated.
_render_routes() {
  local host machine fallback port path ip fip
  while IFS=$'\t' read -r host machine fallback port path; do
    ip=$(N=$machine state_query '.machines[] | select(.name == strenv(N)) | .wg_ip')
    fip=-
    [[ $fallback != - ]] && fip=$(N=$fallback state_query '.machines[] | select(.name == strenv(N)) | .wg_ip')
    printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$fip" "$port" "$path"
  done < <(state_query '(.routes // [])[] | [.host, .machine, .fallback // "-", (.port | tostring), .health_path] | @tsv')
}

_render_traefik_backend() {
  printf '    %s:\n      loadBalancer:\n' "$1"
  printf '        healthCheck:\n          path: %s\n          interval: 10s\n          timeout: 3s\n' "$4"
  printf '        servers:\n          - url: "http://%s:%s"\n' "$2" "$3"
}

# render_dns_zone — the zone file for $STATE_DOMAIN. The serial is a checksum of the records, so it
# changes exactly when they do and the output stays reproducible.
render_dns_zone() {
  local records serial ns name ip
  records=$(_render_dns_records)
  serial=$(cksum <<<"$records" | cut -d' ' -f1)
  ns=$(state_query '[.machines[] | select(.services[] == "coredns") | .wg_ip][0] // .machines[0].wg_ip')
  # shellcheck disable=SC2016 # $ORIGIN and $TTL are zone file directives
  printf '$ORIGIN %s.\n$TTL 300\n' "$STATE_DOMAIN"
  printf '@ IN SOA ns.%s. hostmaster.%s. ( %s 3600 600 86400 300 )\n' "$STATE_DOMAIN" "$STATE_DOMAIN" "$serial"
  printf '@ IN NS ns.%s.\nns IN A %s\n' "$STATE_DOMAIN" "$ns"
  while read -r name ip; do printf '%s IN A %s\n' "$name" "$ip"; done <<<"$records"
}

# render_valkey_acl MACHINE_DIR — Valkey users with SHA-256 password hashes (never the passwords):
# the default user is off, DEFAULT may do anything but administration, VIEWER only reads. Rules apply
# left to right and INFO is @dangerous, so the explicit grants come after -@dangerous.
render_valkey_acl() {
  _secrets_read "$1/secrets.env" || return 1
  local app viewer
  app=$(printf '%s' "${_SECRETS[VALKEY_DEFAULT_PASSWORD]}" | sha256sum | cut -d' ' -f1)
  viewer=$(printf '%s' "${_SECRETS[VALKEY_VIEWER_PASSWORD]}" | sha256sum | cut -d' ' -f1)
  printf 'user default off\n'
  printf 'user %s on #%s ~* &* +@all -@admin\n' "${_SECRETS[VALKEY_DEFAULT_USERNAME]}" "$app"
  printf 'user %s on #%s ~* resetchannels -@all +@read -@dangerous +info +ping +config|get +slowlog|get +latency|latest\n' \
    "${_SECRETS[VALKEY_VIEWER_USERNAME]}" "$viewer"
}

# render_openbao_kv DIR OUT_DIR — DIR/kv/<id>.json for every service of the state with accounts:
# {"<ROLE>_USERNAME": ..., "<ROLE>_PASSWORD": ...} from OUT_DIR/secrets.env. Only the OpenBao
# machine's package gets them: the installer loads them into the KV store (#18: External Secrets).
render_openbao_kv() {
  local dir=$1 id role prefix sep
  local -a ids
  _secrets_read "$2/secrets.env" || return 1
  mapfile -t ids < <(_secrets_state_services)
  mkdir -p "$dir/kv"
  for id in "${ids[@]}"; do
    [[ -n $(catalog_get "$id" SECRETS) ]] || continue
    prefix=$(secrets_prefix "$id") sep=''
    {
      printf '{'
      for role in $(catalog_get "$id" SECRETS); do
        printf '%s"%s_USERNAME": "%s", "%s_PASSWORD": "%s"' "$sep" "$role" "${_SECRETS[${prefix}_${role}_USERNAME]}" \
          "$role" "${_SECRETS[${prefix}_${role}_PASSWORD]}"
        sep=', '
      done
      printf '}\n'
    } >"$dir/kv/$id.json"
  done
}

render_bcrypt_salt() { openssl rand -base64 32 | tr -dc './A-Za-z0-9' | cut -c1-22; }

# _render_bcrypt PASSWORD — bcrypt hash (cost 10) with libxcrypt's crypt() through perl (there is no
# bcrypt in openssl); the password goes to perl on stdin.
_render_bcrypt() {
  local salt hash
  salt=$("$ARGOCD_SALT_GENERATOR")
  [[ $salt =~ ^[./A-Za-z0-9]{22}$ ]] || {
    log_error "bcrypt salt generator $ARGOCD_SALT_GENERATOR returned an invalid salt"
    return 1
  }
  hash=$(printf '%s' "$1" | SALT=$salt perl -e 'my $pw = <STDIN>; print crypt($pw, q($2b$10$) . $ENV{SALT})')
  [[ $hash =~ ^\$2b\$10\$[./A-Za-z0-9]{53}$ ]] || {
    log_error "bcrypt hashing failed (perl crypt without bcrypt support?)"
    return 1
  }
  printf '%s\n' "$hash"
}

# render_argocd DIR OUT_DIR MACHINE_DIR — what only the ArgoCD machine gets: the admin password hash,
# the repository Secret with the read-only deploy key and a cluster Secret per application cluster.
render_argocd() {
  local dir=$1 out_dir=$2 name ip key line hash
  _secrets_read "$3/secrets.env" || return 1
  hash=$(_render_bcrypt "${_SECRETS[ARGOCD_ROOT_PASSWORD]}") || return 1
  mkdir -p "$dir/manifests" "$dir/clusters"
  {
    printf '# ArgoCD admin password (bcrypt of ARGOCD_ROOT_PASSWORD); merged into argocd-secret.\n'
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: argocd-secret\n  namespace: argocd\ntype: Opaque\nstringData:\n'
    printf '  admin.password: "%s"\n  admin.passwordMtime: "2000-01-01T00:00:00Z"\n' "$hash"
  } >"$dir/manifests/10-argocd-admin.yaml"
  key=$(gitops_key_file "$out_dir")
  [[ -r $key ]] || {
    log_error "missing deploy key $key (gitops_ensure_deploy_key)"
    return 1
  }
  {
    printf '# Repository homelab-gitops, read with the read-only deploy key (public half: INSTALL_ORDER.md).\n'
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: repo-homelab-gitops\n  namespace: argocd\n'
    printf '  labels:\n    argocd.argoproj.io/secret-type: repository\ntype: Opaque\nstringData:\n'
    printf '  type: git\n  url: "%s"\n  sshPrivateKey: |\n' "$(state_query '.gitops_repo')"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <"$key"
  } >"$dir/manifests/20-repo.yaml"
  # Application clusters other than ArgoCD's own (that one is in-cluster already).
  while IFS=$'\t' read -r name ip; do
    # yq prints an empty line for an empty selection.
    [[ -z $name || $name == "${3##*/}" ]] && continue
    _render_argocd_cluster "$out_dir" "$name" "$ip" >"$dir/clusters/$name.yaml" || return 1
  done < <(state_query '.machines[] | select(.services[] == "app-cluster") | [.name, .wg_ip] | @tsv')
}

# _render_argocd_cluster OUT_DIR NAME IP — the cluster Secret: the API on the WireGuard address, the
# cluster's own CA and the argocd client certificate signed by its client-ca (lib/ca.sh).
_render_argocd_cluster() {
  local ca=$1/k3s-ca/$2 f
  for f in server-ca.crt argocd.crt argocd.key; do
    [[ -r $ca/$f ]] || {
      log_error "missing $ca/$f (ca_ensure_k3s_cluster)"
      return 1
    }
  done
  printf '# ArgoCD cluster %s (generated by the wizard).\n' "$2"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cluster-%s\n  namespace: argocd\n' "$2"
  printf '  labels:\n    argocd.argoproj.io/secret-type: cluster\ntype: Opaque\nstringData:\n'
  printf '  name: "%s"\n  server: "https://%s:%s"\n' "$2" "$3" "$RENDER_K3S_API_PORT"
  printf '  config: |\n    {"tlsClientConfig": {"caData": "%s", "certData": "%s", "keyData": "%s"}}\n' \
    "$(base64 -w0 <"$ca/server-ca.crt")" "$(base64 -w0 <"$ca/argocd.crt")" "$(base64 -w0 <"$ca/argocd.key")"
}

# _render_service_extras DIR ID MACHINE_DIR — files a service needs that are computed from the
# whole state or from the machine's secrets.
_render_service_extras() {
  case $2 in
    valkey) render_valkey_acl "$3" >"$1/users.acl" ;;
    openbao) render_openbao_kv "$1" "${3%/*}" ;;
    argocd) render_argocd "$1" "${3%/*}" "$3" ;;
    coredns) render_dns_zone >"$1/db.$STATE_DOMAIN" ;;
    traefik)
      mkdir -p "$1/dynamic"
      render_traefik_routes >"$1/dynamic/routes.yml"
      ;;
  esac
}

# _render_install_sh NAME RUNTIME SERVICE... — the machine's install.sh on stdout.
_render_install_sh() {
  local name=$1 runtime=$2 id docker=0
  shift 2
  local -a steps=("${RENDER_BASE_STEPS[@]}")
  for id in "$@"; do [[ $(_render_service_runtime "$id" "$runtime") == compose ]] && docker=1; done
  ((docker)) && steps+=("$RENDER_DOCKER_STEP")
  [[ $runtime == k3s ]] && steps+=("$RENDER_K3S_STEP")
  cat <<EOF
#!/usr/bin/env bash
# Generated by wizard.sh for machine $name.
# Run: sudo ./install.sh [--dry-run] [--force] [--step ID]
#   --step ID  only one step: NN for common/NN-*.sh (03-ssh lives in 03-ufw.sh), NN-id for a service
# Any other argument is rejected: this runs as root.
set -Eeuo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"
# Steps read node.env and secrets.env from here.
export HOMELAB_NODE_DIR=\$PWD
EOF
  printf 'IDS=(%s' "${steps[0]%%-*}"
  for id in "${steps[@]:1}"; do printf ' %s' "${id%%-*}"; done
  for id in "$@"; do printf ' %s-%s' "$(catalog_get "$id" PRIORITY)" "$id"; done
  printf ' %s' "${RENDER_VERIFY_STEP%%-*}"
  printf ')\ndeclare -A ALIASES=(%s)\nSTEPS=(\n' "$RENDER_STEP_ALIASES"
  for id in "${steps[@]}"; do printf '  ../common/%s.sh\n' "$id"; done
  for id in "$@"; do printf '  services/%s/install.sh\n' "$id"; done
  printf '  ../common/%s.sh\n)\n' "$RENDER_VERIFY_STEP"
  cat <<'EOF'
only='' args=()
while (($#)); do
  case $1 in
    --dry-run | --force)
      args+=("$1")
      shift
      ;;
    --step)
      if [[ -n $only || ! ${2:-} =~ ^[0-9]{2}(-[a-z0-9]+)*$ ]]; then
        echo "--step takes one step id, one of: ${IDS[*]} ${!ALIASES[*]}" >&2
        exit 2
      fi
      only=$2
      shift 2
      ;;
    *)
      echo "unknown argument (allowed: --dry-run, --force, --step ID)" >&2
      exit 2
      ;;
  esac
done
[[ -n $only && -n ${ALIASES[$only]-} ]] && only=${ALIASES[$only]}
selected=()
for i in "${!STEPS[@]}"; do
  if [[ -z $only || ${IDS[i]} == "$only" ]]; then selected+=("${STEPS[i]}"); fi
done
((${#selected[@]})) || {
  echo "unknown step: $only (steps: ${IDS[*]})" >&2
  exit 2
}
for f in "${selected[@]}"; do
  [[ -f $f ]] || {
    echo "missing install step: $f" >&2
    exit 1
  }
done
for f in "${selected[@]}"; do bash "$f" "${args[@]}"; done
EOF
}

# _render_copy OUT DEST_DIR FILE... — copies files below OUT keeping their path relative to OUT.
_render_copy() {
  local out_dir=$1 dest=$2 f rel
  shift 2
  for f in "$@"; do
    rel=${f#"$out_dir"/}
    mkdir -p "$dest/$(dirname "$rel")"
    cp -p "$f" "$dest/$rel"
  done
}

# render_machine OUT NAME — OUT/NAME/ (secrets.env and wg0.conf already there) + extras.
render_machine() {
  local out_dir=$1 name=$2 runtime cluster
  local -a services files
  runtime=$(N=$name state_query '.machines[] | select(.name == strenv(N)) | .runtime')
  [[ -n $runtime ]] || {
    log_error "unknown machine: $name"
    return 1
  }
  mapfile -t services < <(_render_services "$name")
  local dir=$out_dir/$name
  # Rebuilt every time, so a removed service or role leaves nothing behind in the package.
  rm -rf "$dir/services" "$dir/ca" "$dir/k3s-ca"
  mkdir -p "$dir"
  _render_node_env "$out_dir" "$name" "${services[*]}"
  local id
  for id in "${services[@]}"; do
    _render_templates "$out_dir" "$name" "$id" || return 1
    _render_service_extras "$out_dir/$name/services/$id" "$id" "$out_dir/$name" || return 1
  done
  _render_install_sh "$name" "$runtime" "${services[@]}" >"$dir/install.sh"
  chmod 700 "$dir/install.sh"
  if [[ " ${services[*]} " == *" step-ca "* ]]; then
    mapfile -t files < <(ca_files_step_ca "$out_dir")
    _render_copy "$out_dir" "$dir" "${files[@]}"
  fi
  if [[ $runtime == k3s ]]; then
    mapfile -t files < <(ca_files_k3s "$out_dir" "$name")
    _render_copy "$out_dir" "$dir" "${files[@]}"
  fi
  if [[ " ${services[*]} " == *" argocd "* ]]; then
    while IFS= read -r cluster; do
      mapfile -t files < <(ca_files_argocd "$out_dir" "$cluster")
      _render_copy "$out_dir" "$dir" "${files[@]}"
    done < <(state_query '.machines[] | select(.runtime == "k3s") | .name')
  fi
}

# render_install_order OUT — machines by the lowest priority of their non-always services.
render_install_order() {
  local out_dir=$1 name ip id min n=0
  {
    printf '# Install order\n\n'
    # shellcheck disable=SC2016 # Markdown backticks, not command substitution
    printf 'Copy `<machine>.tar.gz` to the machine, then: `tar -xzf <machine>.tar.gz && cd <machine> && sudo ./install.sh`\n\n'
    printf '| # | Machine | WG address | Lowest priority | Services |\n| :--- | :--- | :--- | :--- | :--- |\n'
    while IFS=$'\t' read -r name ip; do
      local -a services=()
      mapfile -t services < <(_render_services "$name")
      min=$RENDER_NO_PRIORITY
      for id in "${services[@]}"; do
        [[ $(catalog_get "$id" SCOPE) == always ]] && continue
        ((10#$(catalog_get "$id" PRIORITY) < 10#$min)) && min=$(catalog_get "$id" PRIORITY)
      done
      printf '%s\t%s\t%s\t%s\n' "$min" "$name" "$ip" "${services[*]}"
    done < <(state_query '.machines[] | [.name, .wg_ip] | @tsv') |
      sort -s -t $'\t' -k1,1n |
      while IFS=$'\t' read -r min name ip id; do
        n=$((n + 1))
        printf '| %s | %s | %s | %s | %s |\n' "$n" "$name" "$ip" "$min" "$id" # id: the service list
      done
    if [[ -n $(state_query '[.machines[] | select(.services[] == "argocd")][0] // ""') ]]; then
      printf '\n## GitOps repository (before installing ArgoCD)\n\n'
      # shellcheck disable=SC2016 # Markdown backticks
      printf 'Add this public key to `%s` as a **read-only** deploy key:\n\n```\n%s\n```\n' \
        "$(state_query '.gitops_repo')" "$(gitops_public_key "$out_dir")"
    fi
  } >"$out_dir/INSTALL_ORDER.md"
}

# render_package OUT NAME — OUT/NAME.tar.gz with common/ and NAME/, reproducible (sorted, fixed mtime).
render_package() {
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - -C "$1" common "$2" | gzip -n >"$1/$2.tar.gz"
}

# render_all OUT — every package plus INSTALL_ORDER.md and the root CA for admin devices.
render_all() (
  # Packages hold secrets and keys: everything is created readable only by the owner.
  umask 077
  local out_dir=$1 name
  render_common "$out_dir" || return 1
  while IFS= read -r name; do
    render_machine "$out_dir" "$name" || return 1
    render_package "$out_dir" "$name" || return 1
  done < <(state_query '.machines[].name')
  while IFS= read -r name; do
    cp "$(ca_files_public "$out_dir")" "$out_dir/admin-devices/$name/"
  done < <(state_query '.admin_devices[].name')
  render_install_order "$out_dir"
)
