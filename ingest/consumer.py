#!/usr/bin/env python3
"""Redis Streams -> PostgreSQL batch writer (the ingestion consumer).

Delivery guarantee: AT-LEAST-ONCE.
  1. XREADGROUP a batch      -> messages become "pending" for this consumer
  2. validate, INSERT the batch into events (multi-row, parameterised), COMMIT
  3. XACK + XDEL the batch   -> only now are they gone from Redis
A crash between 2 and 3 re-delivers the batch (rare duplicate events are possible);
a crash before 2 loses nothing. Pending messages of dead consumers are taken over
with XAUTOCLAIM. Invalid messages go to the dead-letter stream `events:dead`.

Connects as the least-privilege login role created by scripts/create_login_roles.sh
(it can INSERT into events and read two lookup lists - nothing else).

  python ingest/consumer.py                 # run forever
  python ingest/consumer.py --until-empty   # drain the stream, then exit
"""
import argparse, json, logging, os, signal, sys, time
from datetime import datetime, timedelta, timezone

import psycopg2
import psycopg2.extras
import redis

STREAM = os.getenv("STREAM_KEY", "events:ingest")
DEAD = os.getenv("DEAD_STREAM_KEY", "events:dead")
GROUP = os.getenv("CONSUMER_GROUP", "pg_writers")
NAME = os.getenv("CONSUMER_NAME", f"consumer-{os.getpid()}")
BATCH = int(os.getenv("BATCH_SIZE", "2000"))
BLOCK_MS = int(os.getenv("BLOCK_MS", "1000"))
CLAIM_IDLE_MS = int(os.getenv("CLAIM_IDLE_MS", "60000"))
MAX_PROPS_BYTES = 8192

# fixed statements - values are NEVER interpolated into SQL text
# NB: COPY is deliberately NOT used: PostgreSQL refuses COPY FROM into a table with
# Row-Level Security enabled ("COPY FROM not supported with row-level security"), and
# the ingest role must never bypass RLS. A multi-row INSERT is allowed by the
# ingest_append policy and still sends the whole batch in one round trip.
INSERT_SQL = "INSERT INTO events (tenant_id, user_id, event_type_id, occurred_at, session_id, properties) VALUES %s"
ROW_TEMPLATE = "(%s, %s, %s, %s::timestamptz, NULLIF(%s, '')::uuid, %s::jsonb)"
TYPES_SQL = "SELECT name, event_type_id FROM event_types"
TENANTS_SQL = "SELECT tenant_id FROM tenants"

log = logging.getLogger("consumer")
running = True


def stop(*_):
    global running
    running = False


def pg_connect():
    return psycopg2.connect(
        host=os.getenv("PGHOST", "localhost"), port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "capstone"),
        user=os.getenv("INGEST_USER", "ingest_svc"), password=os.environ["INGEST_PASSWORD"],
        application_name="events-consumer")


class Lookups:
    """Small dimension caches, refreshed every minute (event types and tenant ids)."""
    def __init__(self, conn):
        self.conn, self.loaded_at = conn, 0.0
        self.types, self.tenants = {}, set()

    def get(self):
        if time.time() - self.loaded_at > 60:
            with self.conn.cursor() as cur:
                cur.execute(TYPES_SQL);   self.types = dict(cur.fetchall())
                cur.execute(TENANTS_SQL); self.tenants = {r[0] for r in cur.fetchall()}
            self.conn.commit()
            self.loaded_at = time.time()
        return self.types, self.tenants


def validate(fields, types, tenants):
    """Returns (row, None) or (None, reason)."""
    try:
        tenant_id = int(fields["tenant_id"]); user_id = int(fields["user_id"])
        etype = types.get(fields["event_type"])
        ts = datetime.fromisoformat(fields["occurred_at"])
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        props = fields.get("properties") or "{}"
        if len(props.encode()) > MAX_PROPS_BYTES:
            return None, "properties too large"
        if not isinstance(json.loads(props), dict):
            return None, "properties must be a JSON object"
    except (KeyError, ValueError, TypeError) as e:
        return None, f"malformed: {e}"
    if tenant_id not in tenants:
        return None, f"unknown tenant {tenant_id}"
    if etype is None:
        return None, f"unknown event_type {fields['event_type']!r}"
    now = datetime.now(timezone.utc)
    if not (now - timedelta(days=30) <= ts <= now + timedelta(minutes=5)):
        return None, "occurred_at outside accepted window (-30d .. +5min)"
    return [tenant_id, user_id, etype, ts.isoformat(), fields.get("session_id", ""), props], None


def decode(d):
    return {(k.decode() if isinstance(k, bytes) else k): (v.decode() if isinstance(v, bytes) else v)
            for k, v in d.items()}


def write_batch(conn, rows):
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(cur, INSERT_SQL, rows, template=ROW_TEMPLATE,
                                       page_size=len(rows))   # whole batch, one statement
    conn.commit()


def process(r, conn, lookups, messages):
    """messages: list of (id, fields). Returns number of events written."""
    types, tenants = lookups.get()
    rows, good_ids, dead = [], [], []
    for mid, raw in messages:
        fields = decode(raw)
        row, err = validate(fields, types, tenants)
        if err:
            dead.append((mid, fields, err))
        else:
            rows.append(row); good_ids.append(mid)
    if rows:
        write_batch(conn, rows)               # COMMIT first ...
    for mid, fields, err in dead:             # ... poison messages are parked, not retried
        r.xadd(DEAD, {**fields, "error": err, "source_id": mid.decode() if isinstance(mid, bytes) else mid},
               maxlen=100_000, approximate=True)
    ids = good_ids + [m for m, _, _ in dead]
    if ids:
        pipe = r.pipeline()
        pipe.xack(STREAM, GROUP, *ids)        # ... then acknowledge
        pipe.xdel(STREAM, *ids)               # and free the memory
        pipe.execute()
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--until-empty", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    signal.signal(signal.SIGINT, stop); signal.signal(signal.SIGTERM, stop)

    r = redis.Redis.from_url(os.getenv("REDIS_URL", "redis://localhost:6379/0"))
    try:
        r.xgroup_create(STREAM, GROUP, id="0", mkstream=True)
    except redis.ResponseError as e:
        if "BUSYGROUP" not in str(e):
            raise
    conn = pg_connect()
    lookups = Lookups(conn)

    total, window_n, window_t = 0, 0, time.time()
    # first: my own un-acked messages from a previous run, then stale ones from dead consumers
    recovering = True
    while running:
        try:
            if recovering:
                res = r.xreadgroup(GROUP, NAME, {STREAM: "0"}, count=BATCH)
                msgs = res[0][1] if res else []
                if not msgs:
                    claimed = r.xautoclaim(STREAM, GROUP, NAME, min_idle_time=CLAIM_IDLE_MS,
                                           start_id="0-0", count=BATCH)
                    msgs = claimed[1]
                if not msgs:
                    recovering = False
                    continue
            else:
                res = r.xreadgroup(GROUP, NAME, {STREAM: ">"}, count=BATCH, block=BLOCK_MS)
                msgs = res[0][1] if res else []
                if not msgs:
                    if a.until_empty:
                        break
                    continue
            n = process(r, conn, lookups, msgs)
            total += n; window_n += n
            if time.time() - window_t >= 5:
                log.info("written %d total | %.0f events/s | stream backlog %d",
                         total, window_n / (time.time() - window_t), r.xlen(STREAM))
                window_n, window_t = 0, time.time()
        except psycopg2.Error as e:           # DB trouble: keep messages pending, retry
            if (e.pgcode or "")[:2] in ("42", "0A"):
                # insufficient privilege / undefined object / feature not supported: retrying
                # can never help. Exit loudly (messages stay pending in Redis, nothing is lost).
                log.critical("permanent database error, giving up: %s", str(e).strip())
                sys.exit(1)
            log.error("database error, will retry: %s", str(e).strip())
            try: conn.rollback()
            except Exception: pass
            time.sleep(2)
            try: conn.close()
            except Exception: pass
            try: conn = pg_connect(); lookups = Lookups(conn)
            except Exception: pass
            recovering = True
    log.info("stopped. total events written: %d", total)


if __name__ == "__main__":
    main()
