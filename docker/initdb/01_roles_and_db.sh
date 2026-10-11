#!/bin/bash
# Runs ONCE, as the postgres superuser, the first time the primary's data dir is created.
# Everything the applications use is created WITHOUT superuser rights.
set -euo pipefail

psql -v ON_ERROR_STOP=1 -U postgres \
     -v admin_pw="$ADMIN_PASSWORD" -v mon_pw="$MONITOR_PASSWORD" -v repl_pw="$REPLICATION_PASSWORD" <<'SQL'
-- schema owner + migration role: can create roles (V4) and databases (restore tests), nothing more
SELECT format('CREATE ROLE capstone_admin LOGIN CREATEROLE CREATEDB PASSWORD %L', :'admin_pw') \gexec
CREATE DATABASE capstone OWNER capstone_admin;
-- monitoring: read-only statistics access via the built-in pg_monitor role
SELECT format('CREATE ROLE monitor_svc LOGIN PASSWORD %L IN ROLE pg_monitor', :'mon_pw') \gexec
-- streaming replication
SELECT format('CREATE ROLE replicator LOGIN REPLICATION PASSWORD %L', :'repl_pw') \gexec
SQL

psql -v ON_ERROR_STOP=1 -U postgres -d capstone <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;   -- needs superuser; used by monitoring
SQL

# allow the replica (another container) to connect for replication
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
