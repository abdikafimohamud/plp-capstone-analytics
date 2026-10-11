#!/usr/bin/env bash
# Logical backup in PostgreSQL custom format (compressed, restorable with pg_restore,
# supports selective + parallel restore).
#   scripts/backup.sh            -> backups/capstone_YYYY-MM-DD.dump  (+ .sha256)
# Equivalent to the lab command:  pg_dump -Fc -f backups/capstone_$(date +%F).dump capstone
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-capstone_admin}" \
       PGPASSWORD="${PGPASSWORD:-${ADMIN_PASSWORD:-}}"
DB="${PGDATABASE:-capstone}"
mkdir -p backups
FILE="backups/${DB}_$(date +%F).dump"

if command -v pg_dump >/dev/null 2>&1; then
  pg_dump -Fc -f "$FILE" "$DB"
else   # no local client tools: dump inside the container, stream to the host
  docker compose exec -T -e PGPASSWORD="$PGPASSWORD" postgres pg_dump -Fc -U "$PGUSER" "$DB" > "$FILE"
fi
sha256sum "$FILE" > "$FILE.sha256"
echo "backup written: $FILE ($(du -h "$FILE" | cut -f1))"

# keep the 7 most recent dumps
ls -1t backups/${DB}_*.dump 2>/dev/null | tail -n +8 | while read -r old; do rm -f "$old" "$old.sha256"; done
