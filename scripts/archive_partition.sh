#!/usr/bin/env bash
# "Compression policy" for plain PostgreSQL: before the retention job drops an old
# monthly partition, keep a compressed copy (pg_dump -Fc uses zlib) in cold storage.
#   scripts/archive_partition.sh events_2026_07
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-capstone_admin}" \
       PGPASSWORD="${PGPASSWORD:-${ADMIN_PASSWORD:-}}"
PART="${1:?usage: archive_partition.sh events_YYYY_MM}"
[[ "$PART" =~ ^events_[0-9]{4}_[0-9]{2}$ ]] || { echo "not a partition name: $PART"; exit 1; }
mkdir -p backups/archive
pg_dump -Fc -t "$PART" -f "backups/archive/$PART.dump" "${PGDATABASE:-capstone}"
echo "archived $PART -> backups/archive/$PART.dump ($(du -h backups/archive/$PART.dump | cut -f1))"
echo "now safe to run:  SELECT * FROM enforce_events_retention(interval '90 days', false);"
