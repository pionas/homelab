#!/usr/bin/env bash
# Runs once, when PostgreSQL initialises an empty data directory: the DEFAULT account with its own
# database, and the read-only VIEWER account for panels and postgres-exporter. Names and passwords
# reach SQL only as psql variables (:"name" / :'value' quoting), never spliced into the statement.
set -Eeuo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  --set=app_user="$POSTGRESQL_DEFAULT_USERNAME" --set=app_pass="$POSTGRESQL_DEFAULT_PASSWORD" \
  --set=viewer_user="$POSTGRESQL_VIEWER_USERNAME" --set=viewer_pass="$POSTGRESQL_VIEWER_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pass';
CREATE DATABASE :"app_user" OWNER :"app_user";
CREATE ROLE :"viewer_user" LOGIN PASSWORD :'viewer_pass';
GRANT pg_monitor, pg_read_all_data TO :"viewer_user";
SQL
