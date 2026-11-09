# shellcheck shell=bash
# Sourced (not executed: no exec bit) by the MariaDB entrypoint once, when it initialises an empty
# data directory, so docker_process_sql runs as root over the socket without a password on the
# command line. Creates the read-only VIEWER account (panels, mysqld-exporter); the DEFAULT account
# comes from MARIADB_USER/MARIADB_DATABASE. The mariadb client has no bound parameters, so the name
# and password are checked against plain characters before they reach SQL.
if [[ ! ${MARIADB_VIEWER_USERNAME:-} =~ ^[a-z][a-z0-9_]{0,31}$ || ! ${MARIADB_VIEWER_PASSWORD:-} =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "homelab: MARIADB_VIEWER_USERNAME/PASSWORD missing or with unexpected characters" >&2
  exit 1
fi
# Grants from the mysqld_exporter documentation (SLAVE MONITOR: MariaDB 10.5+) plus SELECT.
docker_process_sql <<SQL
CREATE USER '${MARIADB_VIEWER_USERNAME}'@'%' IDENTIFIED BY '${MARIADB_VIEWER_PASSWORD}' WITH MAX_USER_CONNECTIONS 5;
GRANT SELECT, PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO '${MARIADB_VIEWER_USERNAME}'@'%';
SQL
