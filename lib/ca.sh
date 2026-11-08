#!/usr/bin/env bash
# shellcheck shell=bash
# Certificate authorities: homelab root + intermediate (OUT/ca) and, per k3s cluster, the CA set
# k3s expects in server/tls before its first start plus the argocd client certificate (OUT/k3s-ca/<name>).
# Existing CAs are never regenerated: machines already trust them.
# shortcut: keys are written without a password (--no-password --insecure), protected only by
#   mode 600 in OUT; fine for the VirtualBox stage, use encrypted keys or a KMS before production.

# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

CA_ROOT_NAME="Homelab Root CA"
CA_INTERMEDIATE_NAME="Homelab Intermediate CA"
# CA files k3s requires in server/tls (docs.k3s.io/cli/certificate, "Using Custom CA Certificates").
# etcd CAs are required even without embedded etcd.
CA_K3S_CAS=(server-ca client-ca request-header-ca etcd/peer-ca etcd/server-ca)
# shortcut: the argocd client certificate lives as long as the CAs (10 years) because renewal is not
#   automated yet; shorten it once rotation exists.
CA_ARGOCD_VALIDITY=87600h

_ca_need_step() {
  # type -P: common/lib.sh defines a `step` function (install step markers), the binary must exist.
  type -P step >/dev/null || {
    log_error "missing tool: step (step-cli) — install from https://github.com/smallstep/cli/releases (docs/jak-pracowac.md, section 4)"
    return 1
  }
}

# _ca_step ARGS... — runs step quietly; its output is shown only when it fails.
_ca_step() {
  local log
  log=$(umask 077 && command step "$@" 2>&1) || {
    log_error "step $1 $2 failed: $log"
    return 1
  }
}

# _ca_missing CRT KEY — 0: both missing (generate), 1: both exist (keep); a lone half is an error,
# because generating it again would replace a CA that may already be trusted.
_ca_missing() {
  if [[ -e $1 && -e $2 ]]; then return 1; fi
  if [[ ! -e $1 && ! -e $2 ]]; then return 0; fi
  log_error "incomplete CA: only one of $1 and $2 exists; restore the missing file instead of regenerating"
  return 2
}

# _ca_create DIR NAME FILE PROFILE [SIGNER_DIR/SIGNER_FILE] — DIR/FILE.crt + DIR/FILE.key unless present.
_ca_create() {
  local dir=$1 name=$2 file=$3 profile=$4 signer=${5:-} rc=0
  _ca_missing "$dir/$file.crt" "$dir/$file.key" || rc=$?
  ((rc != 1)) || return 0
  ((rc == 0)) || return 1
  local -a args=(certificate create "$name" "$dir/$file.crt" "$dir/$file.key" --profile "$profile" --no-password --insecure)
  [[ -n $signer ]] && args+=(--ca "$signer.crt" --ca-key "$signer.key")
  local path=$dir/$file
  (umask 077 && mkdir -p "${path%/*}") || return 1
  _ca_step "${args[@]}"
}

# ca_ensure_root OUT_DIR — OUT_DIR/ca/root_ca.{crt,key}
ca_ensure_root() {
  _ca_need_step || return 1
  _ca_create "$1/ca" "$CA_ROOT_NAME" root_ca root-ca
}

# ca_ensure_intermediate OUT_DIR — OUT_DIR/ca/intermediate_ca.{crt,key}, signed by the root.
ca_ensure_intermediate() {
  _ca_need_step || return 1
  [[ -e $1/ca/root_ca.crt && -e $1/ca/root_ca.key ]] || {
    log_error "root CA missing in $1/ca (run ca_ensure_root first)"
    return 1
  }
  _ca_create "$1/ca" "$CA_INTERMEDIATE_NAME" intermediate_ca intermediate-ca "$1/ca/root_ca"
}

# ca_ensure_k3s_cluster OUT_DIR NAME — OUT_DIR/k3s-ca/NAME: the k3s server/tls CA set and
# argocd.{crt,key} signed by client-ca. The cluster CAs are self-signed, not under the homelab
# root: a client-ca chained to the root would let any certificate step-ca issues log in to the API.
ca_ensure_k3s_cluster() {
  local name=$2 dir=$1/k3s-ca/$2 ca rc=0
  _ca_need_step || return 1
  [[ $(N=$name state_query '[.machines[] | select(.name == strenv(N) and .runtime == "k3s")] | length') == 1 ]] || {
    log_error "not a k3s machine: $name"
    return 1
  }
  for ca in "${CA_K3S_CAS[@]}"; do
    _ca_create "$dir" "k3s-$name-${ca//\//-}" "$ca" root-ca || return 1
  done
  # Service-account token signing key; it has no certificate.
  if [[ ! -e $dir/service.key ]]; then
    rm -f "$dir/service.pub"
    _ca_step crypto keypair "$dir/service.pub" "$dir/service.key" --kty RSA --size 2048 --no-password --insecure || return 1
  fi
  _ca_missing "$dir/argocd.crt" "$dir/argocd.key" || rc=$?
  ((rc != 2)) || return 1
  if ((rc == 0)); then
    _ca_step certificate create argocd "$dir/argocd.crt" "$dir/argocd.key" --profile leaf \
      --not-after "$CA_ARGOCD_VALIDITY" --ca "$dir/client-ca.crt" --ca-key "$dir/client-ca.key" \
      --no-password --insecure || return 1
  fi
}

# Package contents, kept apart so the root key can never be picked up: root_ca.key is in no list.

# ca_files_public OUT_DIR — goes to every package.
ca_files_public() { printf '%s\n' "$1/ca/root_ca.crt"; }

# ca_files_step_ca OUT_DIR — only for the machine running step-ca.
ca_files_step_ca() { printf '%s\n' "$1/ca/intermediate_ca.crt" "$1/ca/intermediate_ca.key"; }

# ca_files_k3s OUT_DIR NAME — the cluster's server/tls files, only for that k3s machine.
ca_files_k3s() {
  local ca
  for ca in "${CA_K3S_CAS[@]}"; do printf '%s\n' "$1/k3s-ca/$2/$ca.crt" "$1/k3s-ca/$2/$ca.key"; done
  printf '%s\n' "$1/k3s-ca/$2/service.key"
}

# ca_files_argocd OUT_DIR NAME — what ArgoCD needs to reach cluster NAME (only for the argocd machine).
ca_files_argocd() { printf '%s\n' "$1/k3s-ca/$2/server-ca.crt" "$1/k3s-ca/$2/argocd.crt" "$1/k3s-ca/$2/argocd.key"; }
