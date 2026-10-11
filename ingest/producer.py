#!/usr/bin/env python3
"""Simulates the product SDKs: pushes events into the Redis Stream.

  python ingest/producer.py --count 200000              # as fast as possible
  python ingest/producer.py --count 50000 --rate 2000   # ~2,000 events/s

The producer never touches PostgreSQL: that is the point of the buffer.
"""
import argparse, json, os, random, time
from datetime import datetime, timezone

import redis

STREAM = os.getenv("STREAM_KEY", "events:ingest")
MAXLEN = int(os.getenv("STREAM_MAXLEN", "5000000"))     # memory guard (approximate trim)
EVENT_TYPES = ["login", "page_view", "feature_used", "invite_sent"]
WEIGHTS = [15, 50, 30, 5]


def make_event(tenant_ids, max_user):
    return {
        "tenant_id": str(random.choice(tenant_ids)),
        "user_id": str(random.randint(1, max_user)),
        "event_type": random.choices(EVENT_TYPES, WEIGHTS)[0],
        "occurred_at": datetime.now(timezone.utc).isoformat(),
        "properties": json.dumps({"device": random.choice(["desktop", "mobile", "tablet"]),
                                  "app_version": random.choice(["3.1", "3.2", "4.0"])}),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=100_000)
    ap.add_argument("--rate", type=int, default=0, help="events/second, 0 = unlimited")
    ap.add_argument("--tenants", default="1,2,3,4,5,6,7,8,9,10")
    ap.add_argument("--max-user", type=int, default=2000)
    ap.add_argument("--batch", type=int, default=500)
    a = ap.parse_args()

    r = redis.Redis.from_url(os.getenv("REDIS_URL", "redis://localhost:6379/0"))
    tenants = [int(t) for t in a.tenants.split(",")]
    sent, t0 = 0, time.time()
    while sent < a.count:
        n = min(a.batch, a.count - sent)
        pipe = r.pipeline(transaction=False)
        for _ in range(n):
            pipe.xadd(STREAM, make_event(tenants, a.max_user), maxlen=MAXLEN, approximate=True)
        pipe.execute()
        sent += n
        if a.rate:
            ahead = sent / a.rate - (time.time() - t0)
            if ahead > 0:
                time.sleep(ahead)
    dt = time.time() - t0
    print(f"produced {sent} events in {dt:.1f}s = {sent / dt:,.0f} events/s | stream length {r.xlen(STREAM)}")


if __name__ == "__main__":
    main()
