# External Secrets -> OpenBao (KV v2 at homelab/), over WireGuard. Applied by install.sh once the
# External Secrets CRDs exist (the operator is installed by ArgoCD, asynchronously).
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
  labels:
    app.kubernetes.io/managed-by: homelab
spec:
  provider:
    vault:
      server: "${OPENBAO_URL}"
      path: homelab
      version: v2
      auth:
        tokenSecretRef:
          name: openbao-token
          namespace: external-secrets
          key: token
