# Install order

Copy `<machine>.tar.gz` to the machine, then: `tar -xzf <machine>.tar.gz && cd <machine> && sudo ./install.sh`

| # | Machine | WG address | Lowest priority | Services |
| :--- | :--- | :--- | :--- | :--- |
| 1 | edge | 10.100.10.100 | 20 | node-exporter coredns step-ca postgresql mariadb rustfs valkey mysqld-exporter postgres-exporter redis-exporter traefik openbao |
