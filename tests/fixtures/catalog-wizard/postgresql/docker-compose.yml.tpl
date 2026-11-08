services:
  postgresql:
    image: postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRESQL_ROOT_USERNAME}
      POSTGRES_PASSWORD: ${POSTGRESQL_ROOT_PASSWORD}
      # Not in the substitution list, so it is left for docker compose.
      PGDATA: ${PGDATA:-/var/lib/postgresql/data}
    ports:
      - "${WG_IP}:5432:5432"
