#!/bin/bash
# Bootstraps a hot-standby streaming replica from the primary on first start.
set -euo pipefail
export PGDATA=/var/lib/postgresql/data
mkdir -p "$PGDATA" && chown postgres:postgres "$PGDATA" && chmod 700 "$PGDATA"

if [ -z "$(ls -A "$PGDATA")" ]; then
  echo "replica: first start, cloning the primary with pg_basebackup"
  until PGPASSWORD="$REPLICATION_PASSWORD" pg_isready -h postgres -U replicator >/dev/null 2>&1; do sleep 1; done
  gosu postgres env PGPASSWORD="$REPLICATION_PASSWORD" \
    pg_basebackup -h postgres -U replicator -D "$PGDATA" -R -X stream -C -S replica_slot -c fast -P
fi
# -R wrote standby.signal + primary_conninfo, so this starts as a read-only standby
exec gosu postgres postgres -c hot_standby=on -c shared_preload_libraries=pg_stat_statements
