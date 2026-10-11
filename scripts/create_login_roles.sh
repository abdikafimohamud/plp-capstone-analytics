#!/usr/bin/env bash
# Creates the LOGIN roles the applications use. Passwords come from the environment
# (.env), never from git. Run once after the migrations (V4 creates the group roles).
#   ingest_svc    -> member of app_ingest    (INSERT events only)
#   dashboard_svc -> member of app_dashboard (read-only, tenant-scoped by RLS)
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
: "${INGEST_PASSWORD:?set INGEST_PASSWORD in .env}" "${DASHBOARD_PASSWORD:?set DASHBOARD_PASSWORD in .env}"

scripts/psql.sh -v ON_ERROR_STOP=1 -v ingest_pw="$INGEST_PASSWORD" -v dash_pw="$DASHBOARD_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE ingest_svc LOGIN PASSWORD %L IN ROLE app_ingest', :'ingest_pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ingest_svc') \gexec
SELECT format('ALTER ROLE ingest_svc PASSWORD %L', :'ingest_pw') \gexec
SELECT format('CREATE ROLE dashboard_svc LOGIN PASSWORD %L IN ROLE app_dashboard', :'dash_pw')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dashboard_svc') \gexec
SELECT format('ALTER ROLE dashboard_svc PASSWORD %L', :'dash_pw') \gexec

-- exporter login (created by docker/initdb or by hand) may read the rollup watermark
SELECT 'GRANT app_monitor TO monitor_svc' WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitor_svc') \gexec

-- guard rails: connection caps and a statement timeout so one bad dashboard query
-- cannot take the database down
ALTER ROLE ingest_svc    CONNECTION LIMIT 10;
ALTER ROLE dashboard_svc CONNECTION LIMIT 50;
ALTER ROLE dashboard_svc SET statement_timeout = '30s';
ALTER ROLE ingest_svc    SET statement_timeout = '60s';
SQL
echo "login roles ready: ingest_svc, dashboard_svc"
