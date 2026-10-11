#!/usr/bin/env bash
# psql wrapper: uses a local psql if installed, otherwise runs psql inside the
# "postgres" docker compose service (the project folder is mounted at /work).
# Connection settings come from .env (see .env.example) or the PG* variables.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" \
       PGUSER="${PGUSER:-capstone_admin}" PGDATABASE="${PGDATABASE:-capstone}" \
       PGPASSWORD="${PGPASSWORD:-${ADMIN_PASSWORD:-}}"
if command -v psql >/dev/null 2>&1; then
  exec psql -X "$@"
fi
args=()
for a in "$@"; do
  if [[ -f "$a" ]]; then args+=("/work/$(realpath --relative-to=. "$a")"); else args+=("$a"); fi
done
exec docker compose exec -T -e PGPASSWORD="$PGPASSWORD" postgres \
     psql -X -U "$PGUSER" -d "$PGDATABASE" "${args[@]}"
