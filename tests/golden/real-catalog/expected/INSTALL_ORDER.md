# Install order

Copy `<machine>.tar.gz` to the machine, then: `tar -xzf <machine>.tar.gz && cd <machine> && sudo ./install.sh`

| # | Machine | WG address | Lowest priority | Services |
| :--- | :--- | :--- | :--- | :--- |
| 1 | vps1 | 10.100.10.101 | 20 | node-exporter coredns step-ca openbao argocd |
| 2 | vps2 | 10.100.10.102 | 30 | node-exporter postgresql mariadb mysqld-exporter postgres-exporter |
| 3 | edge | 10.100.10.100 | 40 | node-exporter traefik |
| 4 | vps3 | 10.100.10.103 | 99 | node-exporter |
