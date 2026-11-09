# MariaDB, published only on the WireGuard address. Passwords come from mariadb.env (mode 600),
# never from this file. Data stays on the host when the container is removed.
services:
  mariadb:
    image: mariadb:11.8.8
    restart: unless-stopped
    env_file: ./mariadb.env
    ports:
      - "${WG_IP}:3306:3306"
    volumes:
      - "/var/lib/homelab/data/mariadb:/var/lib/mysql"
      - "./initdb:/docker-entrypoint-initdb.d:ro"
    security_opt: ["no-new-privileges:true"]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
