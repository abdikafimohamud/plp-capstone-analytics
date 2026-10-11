#!/usr/bin/env bash
# A backup that was never restored is not a backup. This restores the newest dump
# into a scratch database and compares it with the live database.
#   scripts/restore_test.sh [dumpfile]
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-capstone_admin}" \
       PGPASSWORD="${PGPASSWORD:-${ADMIN_PASSWORD:-}}"
DB="${PGDATABASE:-capstone}"; SCRATCH="${DB}_restore_test"
DUMP="${1:-$(ls -1t backups/${DB}_*.dump | head -1)}"
LOG=backups/restore_test.log

client() { local t=$1; shift
  if command -v "$t" >/dev/null 2>&1; then "$t" "$@"
  else docker compose exec -T -e PGPASSWORD="$PGPASSWORD" postgres "$t" -U "$PGUSER" "$@"; fi; }
q() { local d=$1; shift; client psql -X -tA -d "$d" -c "$@"; }

{
echo "== restore test $(date -Is) =="
echo "dump: $DUMP"
sha256sum -c "$DUMP.sha256"

client dropdb --if-exists "$SCRATCH"
client createdb "$SCRATCH"
START=$(date +%s)
client pg_restore --exit-on-error --no-owner -d "$SCRATCH" < "$DUMP"
echo "restore time: $(( $(date +%s) - START )) s"

fail=0
check() {   # label, SQL (single value) -> compares live vs restored
  local a b; a=$(q "$DB" "$2"); b=$(q "$SCRATCH" "$2")
  if [[ "$a" == "$b" ]]; then echo "PASS  $1: $a"; else echo "FAIL  $1: live=$a restored=$b"; fail=1; fi
}
check "events rows"            "SELECT count(*) FROM events"
check "events time range"      "SELECT min(occurred_at)||' .. '||max(occurred_at) FROM events"
check "end_users rows"         "SELECT count(*) FROM end_users"
check "payments revenue (sum)" "SELECT sum(amount_cents) FROM payments WHERE status='succeeded'"
check "audit_log rows"         "SELECT count(*) FROM audit_log"
check "partitions"             "SELECT count(*) FROM pg_inherits WHERE inhparent='events'::regclass"
check "RLS tables"             "SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relrowsecurity"
check "indexes"                "SELECT count(*) FROM pg_indexes WHERE schemaname='public'"
check "rollup users"           "SELECT count(*) FROM agg_user_activity"

client dropdb "$SCRATCH"
if [[ $fail -eq 0 ]]; then echo "RESULT: PASS - backup restores and matches the live database"
else echo "RESULT: FAIL"; fi
exit $fail
} 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
