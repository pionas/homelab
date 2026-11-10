# ArgoCD UI at ${ARGOCD_HOST}, through the k3s Traefik of this machine — reachable from the WireGuard
# network only (UFW, step 03). Certificate from step-ca (resolver stepca, k3s/traefik-acme.yaml).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: homelab
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: stepca
spec:
  ingressClassName: traefik
  rules:
    - host: "${ARGOCD_HOST}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
