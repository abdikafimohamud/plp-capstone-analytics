# Track C: Real-Time Analytics Platform. Requirements Summary

## 1. Purpose
An event-analytics backend for a multi-tenant SaaS. Customer apps (**tenants**) send user events at volume. The platform answers three product questions quickly: **funnels** (where do users drop off), **retention** (do they come back), and **revenue** (what do cohorts pay).

## 2. Actors
| Actor | Needs |
|---|---|
| Tenant analyst | Dashboards: funnel conversion, rolling 7/30-day retention, DAU, revenue by cohort |
| Tenant app (SDK) | Fire-and-forget event ingestion; never blocked by database write latency |
| Platform operator | Monitoring, backups, retention, failover, safe schema changes |

## 3. Functional requirements
1. Ingest events (`tenant_id`, `user_id`, event type, `occurred_at`, JSON `properties`).
2. Buffer ingestion in **Redis Streams**; a consumer batch-inserts into PostgreSQL with at-least-once delivery and a dead-letter stream for invalid events.
3. Tenants define **funnels** as ordered steps over event types, with a time window.
4. Compute funnel conversion, **rolling 7-day and 30-day retention by signup cohort**, DAU with a moving average, revenue by cohort and plan, and JSONB campaign attribution.
5. Dashboard metrics come from **pre-aggregated rollup tables and a materialized view**, not raw scans.
6. Strict tenant isolation: **Row-Level Security** on every tenant-scoped table.
7. **Audit log** on critical tables (tenants, plans, subscriptions, payments); append-only.
8. **Retention:** raw events kept 90 days (old monthly partitions dropped, archived first); aggregates kept indefinitely.
9. Dashboards read from a **streaming replica** (read scaling and hot standby).

## 4. Non-functional requirements (targets)
| Area | Target |
|---|---|
| Ingest | 5,000 events/s sustained; design for ~1B events/year |
| Benchmark data | 10M+ events, 100k users, 10 tenants of very different size |
| Dashboard latency | p95 < 1 s; the retention query sub-second on millions of events |
| Availability | RPO < 1 min, RTO < 5 min (streaming replication + automated failover, WAL archiving as safety net) |
| Security | Least-privilege roles (no app superuser), RLS, hashed PII, parameterised queries only |
| Recoverability | Backups taken **and** a test restore performed |
| Observability | Prometheus + Grafana: connections, TPS, cache hit ratio, replication lag, partition sizes, Redis stream backlog |

## 5. Design decisions (all three open questions are now resolved)
| # | Question | Decision | Why |
|---|---|---|---|
| 1 | Partition size | **Monthly** range partitions on `occurred_at` | ~12 partitions/year keeps planning fast; dropping a month is instant, with no huge `DELETE` |
| 2 | Enforce `events` foreign keys? | **No FK to `tenants` or `end_users`** (only to `event_types`); the consumer validates tenant and type | Per-row FK checks cost ingest throughput on the hottest table |
| 3 | Partitioning engine | **Native PostgreSQL partitioning** with own maintenance functions (`ensure_events_partitions`, `enforce_events_retention`); no pg_partman, no TimescaleDB | Shows the mechanics; fewer dependencies. TimescaleDB remains the alternative (native compression) |
| 4 | Pre-aggregation | Three **rollup tables** + one **materialized view**, exposed through tenant-filtered views | Materialized views cannot have RLS; the filtering views restore isolation |
| 5 | Tenancy model | **Shared tables with `tenant_id` + RLS**, `tenant_id` leading every index | Scales to thousands of tenants (a database or schema per tenant does not) |
| 6 | Indexing | **BRIN** on `occurred_at`; covering and GIN B-tree indexes for query patterns | BRIN is tiny for time-ordered data; the others serve specific queries |

## 6. Scope
**In:** schema as Flyway migrations, Redis Streams ingestion, five analytical queries with before/after evidence, aggregates, retention policy, replica, monitoring, backup and restore test, RLS, audit.
**Out:** client SDKs, a login/authentication UI, a real payment-provider integration, ML features.

## 7. Assumptions
- Tenants identify users with their own `external_id`; only an HMAC hash of the email is stored.
- Amounts are integer cents; subscriptions generate payments (some failed or refunded).
- Events are append-only; a correction is a new event, never an update.

## 8. Entities and cardinalities (full detail in `er_diagram.dbml`)
| Relationship | Cardinality | Enforced? |
|---|---|---|
| plans → tenants | 1 : N | FK |
| plans → subscriptions | 1 : N | FK |
| tenants → end_users | 1 : N | FK |
| tenants → funnels | 1 : N | FK |
| funnels → funnel_steps | 1 : N (ordered) | FK, cascade delete |
| event_types → events | 1 : N | FK |
| event_types → funnel_steps | 1 : N | FK |
| end_users → subscriptions | 1 : N | FK (composite `tenant_id, user_id`) |
| subscriptions → payments | 1 : N | FK |
| tenants → events | 1 : N | **logical only** |
| end_users → events | 1 : N | **logical only** |
| tenants → audit_log | 1 : N | logical (rows outlive tenants) |

**Derived objects** (rebuilt by `refresh_rollups()`, never written by hand): `agg_user_activity`, `agg_daily_active_users`, `agg_daily_events` (tables), `mv_daily_revenue` (materialized view), `rollup_state` (watermark), and the tenant-filtered views `v_user_activity`, `v_daily_active_users`, `v_daily_events`, `v_daily_revenue`.

## 9. Diagram
`er_diagram.dbml` (paste into dbdiagram.io: Import → DBML). `er_diagram.png` / `er_diagram.svg` are pre-rendered copies. Architecture and data flow: `architecture.md`.
