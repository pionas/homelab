# Install order

Copy `<machine>.tar.gz` to the machine, then: `tar -xzf <machine>.tar.gz && cd <machine> && sudo ./install.sh`

| # | Machine | WG address | Lowest priority | Services |
| :--- | :--- | :--- | :--- | :--- |
| 1 | vps1 | 10.100.10.101 | 20 | node-exporter coredns step-ca openbao argocd |
| 2 | vps2 | 10.100.10.102 | 30 | node-exporter postgresql mariadb rustfs valkey redpanda typesense mysqld-exporter postgres-exporter redis-exporter |
| 3 | edge | 10.100.10.100 | 40 | node-exporter traefik |
| 4 | vps3 | 10.100.10.103 | 60 | node-exporter app-cluster |

## GitOps repository (before installing ArgoCD)

Add this public key to `git@example.com:pionas/homelab-gitops.git` as a **read-only** deploy key:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO1gE84SBibxMZLRqJYUJ+mk6J7i5bGyZ5yN/+Onkswa
```
