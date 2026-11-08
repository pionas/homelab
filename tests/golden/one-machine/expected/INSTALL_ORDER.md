# Install order

Copy `<machine>.tar.gz` to the machine, then: `tar -xzf <machine>.tar.gz && cd <machine> && sudo ./install.sh`

| # | Machine | WG address | Lowest priority | Services |
| :--- | :--- | :--- | :--- | :--- |
| 1 | edge | 10.100.10.100 | 21 | node-agent step-ca postgresql postgres-exporter traefik |
