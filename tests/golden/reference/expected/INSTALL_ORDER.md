# Install order

Copy `<machine>.tar.gz` to the machine, then: `tar -xzf <machine>.tar.gz && cd <machine> && sudo ./install.sh`

| # | Machine | WG address | Lowest priority | Services |
| :--- | :--- | :--- | :--- | :--- |
| 1 | vps1 | 10.100.10.101 | 20 | node-agent coredns step-ca openbao argocd |
| 2 | vps2 | 10.100.10.102 | 30 | node-agent postgresql redis postgres-exporter |
| 3 | edge | 10.100.10.100 | 40 | node-agent traefik |
| 4 | vps3 | 10.100.10.103 | 60 | node-agent app-cluster |
| 5 | vps4 | 10.100.10.104 | 60 | node-agent app-cluster |
| 6 | vps5 | 10.100.10.105 | 99 | node-agent |

## GitOps repository (before installing ArgoCD)

Add this public key to `git@example.com:pionas/homelab-gitops.git` as a **read-only** deploy key:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO1gE84SBibxMZLRqJYUJ+mk6J7i5bGyZ5yN/+Onkswa
```
