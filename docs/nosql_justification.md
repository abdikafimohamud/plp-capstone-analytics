# Day 3: why Redis Streams (and why not MongoDB)

## Choice: Redis Streams as the ingestion buffer
Problem: SDKs fire events at bursty, unpredictable rates. Writing each event straight into
PostgreSQL ties the SDK to commit latency and database availability.

What Redis Streams does better than PostgreSQL here
- Acknowledged append in memory (AOF everysec): the SDK never waits for a database commit or an fsync.
- Absorbs bursts: measured on this project, the producer queued 200,000 events at 16,833 events/s
  while the consumer wrote at ~6,500-7,000 events/s. The backlog peaked near 164,000 and drained to 0.
- Consumer groups + XACK give at-least-once delivery; XAUTOCLAIM recovers a dead consumer's batch.
- Invalid events go to a dead-letter stream (events:dead) instead of blocking the pipeline.
- The backlog (XLEN) is a direct, graphable health signal.
- A queue table inside PostgreSQL would add write amplification, dead tuples/vacuum work and WAL,
  all competing with the analytics workload on the same server.

Trade-offs (accepted)
- AOF everysec: a hard crash of Redis can lose up to ~1 second of buffered events.
- At-least-once: a crash between COMMIT and XACK can redeliver one batch (rare duplicates).
- Redis is one more component to run and monitor (redis_exporter is in the monitoring setup).

## Verified result (this project, 200,000-event run)
- 200,000 events produced, 200,000 written: table grew from 47,569 to 247,569 rows.
- Dead-letter stream: 0 entries. Pending (unacknowledged) messages: 0.

## Considered and rejected
- MongoDB: the variable part of an event (device, campaign, ...) is already handled by JSONB + a GIN
  index in PostgreSQL, and keeps joins, transactions and Row-Level Security in one system. A document
  store would add a second database to secure, back up and keep consistent, for no gain.
- Kafka: stronger durability and replay, but much heavier to operate than this scale needs.
  Redis Streams can be swapped for it later without changing the PostgreSQL side.
