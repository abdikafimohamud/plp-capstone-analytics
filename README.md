# Track C: Real-Time Analytics Platform

Event-analytics backend for a multi-tenant SaaS: ingest user events through **Redis Streams**
into a **partitioned PostgreSQL** events table, answer funnel / retention / revenue questions
in milliseconds, with tenant isolation (RLS), audit, backups, a streaming replica and
Prometheus + Grafana monitoring.

```
SDK/app ──▶ Redis Streams ──▶ consumer (batch INSERT) ──▶ PostgreSQL primary ──WAL──▶ streaming replica
            (buffer, at-least-once)   events:ingest            events (monthly partitions, BRIN)        │
                                      events:dead (poison)     rollups + materialized view              ▼
                                                               audit_log, RLS                     dashboards (read)
                              postgres_exporter / redis_exporter ──▶ Prometheus ──▶ Grafana
```

## Where each lab deliverable lives

| Lab step | Deliverable | Files |
|---|---|---|
| Day 1 | Requirements, ER diagram, architecture diagram | `docs/requirements.md`, `docs/er_diagram.dbml` (paste into dbdiagram.io) + `er_diagram.png/.svg`, `docs/architecture.md` + `architecture.png` |
| Day 2 | Versioned migrations | `migrations/V1`..`V7` (V1 core, V2 indexes, V3 audit, V4 RLS, V5 seed, V6 optimizations, V7 retention) |
| Day 3 | NoSQL layer (Redis Streams) | `ingest/producer.py`, `ingest/consumer.py`, `docker-compose.yml` (redis) |
| Day 4 | Optimization evidence | `queries/`, `scripts/benchmark.py`, **`docs/query_optimization.md`**, `docs/benchmarks/` |
| Day 5 | Backup + security | `scripts/backup.sh`, `scripts/restore_test.sh`, `tests/security_check.py` (the 6-point checklist) |
| Extras | Replica, monitoring | `docker/replica-entrypoint.sh`, `monitoring/` |

## Run it (Docker)

```bash
cp .env.example .env                 # then change every password
docker compose up -d
docker compose run --rm flyway clean migrate     # the lab command: builds everything from empty
scripts/create_login_roles.sh        # ingest_svc / dashboard_svc (passwords from .env)
make bulk                            # ~10M events (a few minutes)
make bench-before && make bench-after            # before/after evidence -> docs/query_optimization.md
make ingest-demo                     # 200k events through Redis -> PostgreSQL
make security backup restore-test    # checklist items 1-6
```
No Docker? Point `PG*` variables at any PostgreSQL 16 and use `scripts/migrate_local.sh clean`
(a stand-in for `flyway clean migrate`).

## Results (PostgreSQL 16, 10.3M events, 100k users, tenant 1 = largest, median of 5 runs)

| Query | Before | After | Change |
|---|---:|---:|---|
| Q1 Funnel conversion | 536 ms | 23.7 ms | covering index `(tenant_id, event_type_id, occurred_at) INCLUDE (user_id)` |
| Q2 Rolling 7/30-day retention | 974 ms | 49.0 ms | per-user activity rollup (identical rows verified) |
| Q3 DAU + 7-day moving avg | 1,517 ms | 0.13 ms | daily rollup table (identical rows verified) |
| Q4 Revenue by cohort/plan | 14.1 ms | 0.47 ms | materialized view (identical rows verified) |
| Q5 JSONB campaign attribution | 781 ms | 211 ms | GIN index on `properties` |

Also: BRIN on `occurred_at` halves a time-range scan (46 ms to 23 ms); RLS adds no measurable
cost (24.0 vs 23.2 ms). Q3's rollup is a lookup instead of a 10M-row scan, so its cost moves to
`refresh_rollups()` (incremental), and Q5 is the one that is still not sub-100 ms.

> **These numbers came from a 2-vCPU sandbox, not your machine.** Re-run `make bench-before
> bench-after` and use your own output as your evidence; the lab asks you to measure.

## What was verified (and what was not)

Verified by actually running it on PostgreSQL 16 from an empty database:
- All 7 migrations apply cleanly, and a second `clean` works (roles are cluster-level, so V4 is idempotent).
- Security checklist: `tests/security_check.py` **31/31**.
- Backup (388 MB, 41 s) restored into a scratch DB (71 s); 9 comparisons vs live all match.
- Redis Streams ingestion: 200,000 events in, 200,000 stored, 0 lost, 0 duplicated, 0 dead-lettered (~13.8k events/s, one consumer).
- All five Prometheus custom queries execute; YAML/JSON/shell syntax valid; `docker compose config` parses.

**Not run** (no Docker daemon in the build sandbox): the compose stack itself, the streaming replica
(`docker/replica-entrypoint.sh`), Prometheus scraping and the Grafana dashboard. Expect to debug
those on first `docker compose up`.

## Bugs found and fixed while verifying

1. **Ingest consumer could never insert.** It used `COPY`, which PostgreSQL refuses on tables with
   Row-Level Security, so every batch failed and the consumer retried forever. Now a parameterised
   multi-row `INSERT`; permanent errors (permissions) exit loudly instead of looping.
2. **Missing statistics on small tables.** `funnels`/`funnel_steps` were never `ANALYZE`d, so the
   planner guessed 11 rows (actual 4) and hashed ~1.2M events: Q1 took 197 ms instead of 21 ms.
   V5 now analyzes them. (It also made the "RLS is 15x faster" experiment meaningless.)
3. `q2_retention_raw.sql` had a literal `%` in a comment that psycopg2 treated as a placeholder.
4. Two security-check issues: a flawed test (a random hash contains the byte `@` about 12% of the
   time) and string concatenation in `benchmark.py` (now `psycopg2.sql`).

## Before you push to GitHub
`.env` and `backups/*.dump` are git-ignored. Make sure no real password is in any committed file.
