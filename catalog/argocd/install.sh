#!/usr/bin/env bash
# Service argocd (priority 50, k3s): ArgoCD from its pinned upstream manifest (checksum verified),
# the admin password, the homelab-gitops repository with the read-only deploy key, a cluster Secret
# per application cluster, External Secrets as the first application and its store in OpenBao.
# Runs from the package: <machine>/services/argocd/install.sh (only this package has the keys).
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=argocd
ARGOCD_VERSION=v3.5.6
ARGOCD_MANIFEST_URL=https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
ARGOCD_MANIFEST_SHA256=846c644bc81ce5557dd9048757a9c7353378f25c5eb811c77d32a9e907823599
ESO_CRD=clustersecretstores.external-secrets.io
WAIT_SECONDS=600

kubectl() { run k3s kubectl "$@"; }

# wait_for CHECK_DESCRIPTION COMMAND... — polls a read-only command with a deadline.
wait_for() {
  local what=$1 deadline=$((SECONDS + WAIT_SECONDS))
  shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "$what not ready after ${WAIT_SECONDS}s"
    sleep 5
  done
}

install_argocd() {
  local runtime manifest=$HOMELAB_STATE_DIR/argocd-install-$ARGOCD_VERSION.yaml f
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == k3s ]] || die "$SERVICE_ID runs only in k3s"
  for f in manifests/00-namespaces.yaml manifests/10-argocd-admin.yaml manifests/20-repo.yaml \
    manifests/30-openbao-token.yaml manifests/40-external-secrets-app.yaml manifests/50-root-app.yaml \
    store/cluster-secret-store.yaml; do
    [[ -r $SERVICE_DIR/$f ]] || die "missing $SERVICE_DIR/$f: only the ArgoCD machine's package has it"
  done
  grep -q 'server: "http://[0-9]' "$SERVICE_DIR/store/cluster-secret-store.yaml" ||
    die "cluster-secret-store.yaml has no OpenBao address: the plan needs OpenBao (REQUIRES)"
  if in_container; then
    container_skip "installing ArgoCD (k3s does not run in the container)"
    return 0
  fi
  ((DRY_RUN)) || wait_for "k3s API" k3s kubectl get --raw=/readyz
  run install -d -m 700 "$HOMELAB_STATE_DIR"
  fetch "$ARGOCD_MANIFEST_URL" "$manifest"
  verify_sha256 "$manifest" "$ARGOCD_MANIFEST_SHA256"
  kubectl apply -f "$SERVICE_DIR/manifests/00-namespaces.yaml"
  # Server-side: the ArgoCD CRDs are too large for client-side apply annotations.
  kubectl apply --server-side --force-conflicts -n argocd -f "$manifest"
  kubectl apply --server-side --force-conflicts -f "$SERVICE_DIR/manifests/"
  if compgen -G "$SERVICE_DIR/clusters/*.yaml" >/dev/null; then
    kubectl apply -f "$SERVICE_DIR/clusters/"
  fi
  run rm -f "$manifest"
  # ArgoCD installs External Secrets asynchronously; its CRDs must exist before the store.
  if ((DRY_RUN)); then
    log_info "would wait for CRD $ESO_CRD (External Secrets, synced by ArgoCD)"
  else
    wait_for "External Secrets CRD $ESO_CRD" k3s kubectl get crd "$ESO_CRD"
    k3s kubectl wait --for=condition=Established --timeout="${WAIT_SECONDS}s" crd/"$ESO_CRD" >/dev/null
  fi
  kubectl apply -f "$SERVICE_DIR/store/cluster-secret-store.yaml"
  log_info "ArgoCD $ARGOCD_VERSION installed; $(compgen -G "$SERVICE_DIR/clusters/*.yaml" | wc -l) cluster(s) registered"
}

step "50-$SERVICE_ID" install_argocd
