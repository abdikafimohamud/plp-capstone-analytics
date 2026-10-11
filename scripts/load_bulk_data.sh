#!/usr/bin/env bash
# Replace the small demo data with the benchmark dataset (~10M events, 100k users).
#   scripts/load_bulk_data.sh [total_users] [avg_events_per_user]
# Takes a few minutes. Safe to re-run (it TRUNCATEs first).
set -euo pipefail
cd "$(dirname "$0")/.."
USERS="${1:-100000}"; AVG="${2:-115}"
PSQL=scripts/psql.sh

echo ">> generating $USERS users x ~$AVG events (this takes a few minutes)"
$PSQL -v ON_ERROR_STOP=1 -c "\\timing on" -c "SELECT * FROM seed_demo_data($USERS, $AVG, 90, true)"

echo ">> VACUUM ANALYZE (sets the visibility map -> enables index-only scans)"
$PSQL -v ON_ERROR_STOP=1 -c "VACUUM (ANALYZE) events" -c "VACUUM (ANALYZE) end_users" \
      -c "VACUUM (ANALYZE) subscriptions" -c "VACUUM (ANALYZE) payments"

echo ">> rebuilding rollups / materialized view if they exist (V6 applied)"
$PSQL -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
    IF to_regproc('refresh_rollups') IS NOT NULL THEN
        PERFORM refresh_rollups('1970-01-01');
        REFRESH MATERIALIZED VIEW mv_daily_revenue;
    END IF;
END $$;
SQL
$PSQL -c "SELECT count(*) AS events, pg_size_pretty(sum(pg_total_relation_size(inhrelid))) AS events_total_size FROM pg_inherits WHERE inhparent = 'events'::regclass"
