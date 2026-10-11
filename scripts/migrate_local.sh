#!/usr/bin/env bash
# Stand-in for Flyway on machines WITHOUT Docker/Flyway: applies migrations/V*.sql
# in version order, each in its own transaction (what Flyway does for PostgreSQL).
#
#   scripts/migrate_local.sh clean        # drop + recreate schema "public", then migrate all
#   scripts/migrate_local.sh migrate      # apply everything not applied yet
#   scripts/migrate_local.sh migrate 5    # apply up to version 5 (Flyway: -target=5)
#
# Uses PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE (see .env.example).
# For the real thing use:  docker compose run --rm flyway clean migrate
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-migrate}"; target="${2:-999}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS schema_history_local (version int PRIMARY KEY, script text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())" >/dev/null 2>&1 || true

if [[ "$cmd" == "clean" ]]; then
  echo ">> clean: dropping and recreating schema public"
  "${PSQL[@]}" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
  "${PSQL[@]}" -c "CREATE TABLE schema_history_local (version int PRIMARY KEY, script text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())"
fi

for f in $(ls migrations/V*__*.sql | sort -V); do
  v=$(basename "$f" | sed -E 's/^V([0-9]+)__.*/\1/')
  (( v > target )) && continue
  if [[ -n "$("${PSQL[@]}" -tA -c "SELECT 1 FROM schema_history_local WHERE version=$v")" ]]; then
    continue
  fi
  echo ">> applying $(basename "$f")"
  "${PSQL[@]}" --single-transaction -f "$f" >/dev/null
  "${PSQL[@]}" -c "INSERT INTO schema_history_local (version, script) VALUES ($v, '$(basename "$f")')"
done
echo ">> done"
