# node_exporter for a k3s machine (single node), applied by k3s from its manifests directory.
# Host network, listening only on the WireGuard address.
apiVersion: v1
kind: Namespace
metadata:
  name: homelab-monitoring
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: homelab-monitoring
  labels:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/managed-by: homelab
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-exporter
    spec:
      hostNetwork: true
      hostPID: true
      automountServiceAccountToken: false
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.12.1
          args:
            - "--path.rootfs=/host"
            - "--web.listen-address=${WG_IP}:${PORT_9100}"
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 65534
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: root
              mountPath: /host
              readOnly: true
              mountPropagation: HostToContainer
      volumes:
        - name: root
          hostPath:
            path: /
