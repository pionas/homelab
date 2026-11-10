#!/usr/bin/env bash
# shellcheck shell=bash
# Read-only deploy key for the homelab-gitops repository: ArgoCD pulls the repository with it. The
# wizard generates it once (OUT/gitops/deploy_key, mode 600); the public half must be added to the
# repository as a read-only deploy key by hand (INSTALL_ORDER.md says so).

# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Injectable so golden tests get a stable key: GITOPS_KEYGEN PRIVATE_KEY_PATH writes the key pair.
GITOPS_KEYGEN=${GITOPS_KEYGEN:-gitops_keygen}
GITOPS_KEY_COMMENT=homelab-argocd

gitops_keygen() { ssh-keygen -q -t ed25519 -N '' -C "$GITOPS_KEY_COMMENT" -f "$1"; }

gitops_key_file() { printf '%s/gitops/deploy_key\n' "$1"; }

# gitops_ensure_deploy_key OUT_DIR — creates the key pair unless it exists; checks it is a key pair.
gitops_ensure_deploy_key() {
  local key
  key=$(gitops_key_file "$1")
  if [[ ! -e $key ]]; then
    (umask 077 && mkdir -p "${key%/*}" && "$GITOPS_KEYGEN" "$key") || {
      log_error "deploy key generator $GITOPS_KEYGEN failed"
      return 1
    }
  fi
  chmod 600 "$key"
  if ! ssh-keygen -y -f "$key" >/dev/null 2>&1 || [[ ! -r $key.pub ]]; then
    log_error "$key is not a usable private key with $key.pub next to it" # never print the key
    return 1
  fi
}

# gitops_public_key OUT_DIR — the line to add to the repository as a read-only deploy key.
gitops_public_key() { cut -d' ' -f1,2 "$(gitops_key_file "$1").pub"; }
