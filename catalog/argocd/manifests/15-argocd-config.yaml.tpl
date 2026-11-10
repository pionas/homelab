# ArgoCD's address and plain HTTP behind the ingress (TLS ends at the k3s Traefik, 60-ingress.yaml).
# Merged into the ConfigMaps from install.yaml (server-side apply).
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: "https://${ARGOCD_HOST}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  server.insecure: "true"
