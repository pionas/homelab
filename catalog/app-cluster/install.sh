#!/usr/bin/env bash
# Service app-cluster (priority 60, k3s): marks a cluster ArgoCD manages. Nothing to install here —
# ArgoCD (on its own machine) registers the cluster with the wizard's cluster Secret; this checks
# the cluster is ready for it: the k3s API runs and the argocd RBAC binding (step 11) is there.
set -Eeuo pipefail
SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common/lib.sh
source "$SERVICE_DIR/../../../common/lib.sh"
parse_common_args "$@"
require_root
load_node_env

SERVICE_ID=app-cluster
RBAC_BINDING=homelab-argocd

check_app_cluster() {
  local runtime
  runtime=$(service_runtime "$SERVICE_ID") || exit 1
  [[ $runtime == k3s ]] || die "$SERVICE_ID runs only on a k3s machine"
  if in_container; then
    container_skip "application cluster checks (k3s does not run in the container)"
    return 0
  fi
  if ((DRY_RUN)); then
    log_info "would check the k3s API and the $RBAC_BINDING binding"
    return 0
  fi
  k3s kubectl get --raw=/readyz >/dev/null 2>&1 || die "k3s API is not ready (step 11): journalctl -u k3s"
  k3s kubectl get clusterrolebinding "$RBAC_BINDING" >/dev/null 2>&1 ||
    die "ClusterRoleBinding $RBAC_BINDING is missing: ArgoCD could not manage this cluster (step 11)"
  log_info "application cluster ready: ArgoCD reaches it at https://$WG_IP:6443"
}

step "60-$SERVICE_ID" check_app_cluster
