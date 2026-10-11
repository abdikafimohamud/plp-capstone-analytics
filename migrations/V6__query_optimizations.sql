-- V6__query_optimizations.sql
-- Day-4 optimisations. Each block names the query it was written for; the measured
-- before/after evidence is in docs/query_optimization.md.
--
-- PRODUCTION NOTE: CREATE INDEX on a partitioned table takes a SHARE lock on every
-- partition. On a live system build the index with the zero-downtime recipe instead:
--   CREATE INDEX ... ON ONLY events (...);                 -- invalid, instant
--   CREATE INDEX CONCURRENTLY ... ON events_2026_10 (...); -- per partition
--   ALTER INDEX parent_idx ATTACH PARTITION child_idx;     -- parent becomes valid
-- (CONCURRENTLY cannot run inside a migration transaction, hence not used here.)

-- ======================================================= Q1  funnel conversion
-- Funnel steps are 4 of 8 event types, but ~95% of the rows in a tenant's time
-- window are engagement events. A covering index keyed (tenant, type, time) with
-- user_id INCLUDEd lets the planner read ONLY the funnel events, index-only.
CREATE INDEX events_tenant_type_time_cov
    ON events (tenant_id, event_type_id, occurred_at) INCLUDE (user_id);

-- user timeline drill-down ("what did user X do?"); also used by the consumer's lookups
CREATE INDEX events_tenant_user_time
    ON events (tenant_id, user_id, occurred_at);

-- ============================================ Q5  JSONB campaign attribution
-- jsonb_path_ops: smaller/faster than default jsonb_ops, supports @> containment.
-- btree_gin lets tenant_id live in the same GIN index, so one bitmap probe is
-- already tenant-scoped.
CREATE INDEX events_properties_gin
    ON events USING gin (tenant_id, properties jsonb_path_ops);

-- ====================================================== Q4  revenue per cohort
CREATE INDEX payments_tenant_paid_cov
    ON payments (tenant_id, paid_at) INCLUDE (subscription_id, amount_cents, status);

-- Revenue is small and changes rarely: a MATERIALIZED VIEW refreshed on a schedule
-- (REFRESH ... CONCURRENTLY, so dashboards never block) is the right tool.
CREATE MATERIALIZED VIEW mv_daily_revenue AS
SELECT p.tenant_id,
       (p.paid_at AT TIME ZONE 'UTC')::date                              AS day,
       date_trunc('month', u.signup_at AT TIME ZONE 'UTC')::date         AS cohort_month,
       s.plan_id,
       count(*)                                                          AS payments,
       count(*) FILTER (WHERE p.status = 'succeeded')                    AS succeeded_payments,
       coalesce(sum(p.amount_cents) FILTER (WHERE p.status = 'succeeded'), 0) AS revenue_cents,
       coalesce(sum(p.amount_cents) FILTER (WHERE p.status = 'refunded'),  0) AS refunded_cents
FROM payments p
JOIN subscriptions s ON s.subscription_id = p.subscription_id
JOIN end_users u     ON u.tenant_id = s.tenant_id AND u.user_id = s.user_id
GROUP BY 1, 2, 3, 4;

CREATE UNIQUE INDEX mv_daily_revenue_pk
    ON mv_daily_revenue (tenant_id, day, cohort_month, plan_id);   -- needed for CONCURRENTLY

-- ================================================ Q2, Q3  incremental rollups
-- Event-derived aggregates are plain tables maintained INCREMENTALLY, not
-- materialized views: raw partitions are dropped after 90 days (V7), and a full
-- REFRESH MATERIALIZED VIEW would silently erase the history we want to keep.
-- This is the same idea as a TimescaleDB continuous aggregate.
CREATE TABLE agg_user_activity (
    tenant_id      int         NOT NULL,
    user_id        bigint      NOT NULL,
    first_event_at timestamptz NOT NULL,
    last_event_at  timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, user_id)
);

CREATE TABLE agg_daily_active_users (
    tenant_id int    NOT NULL,
    day       date   NOT NULL,
    dau       int    NOT NULL,
    PRIMARY KEY (tenant_id, day)
);

CREATE TABLE agg_daily_events (
    tenant_id     int      NOT NULL,
    day           date     NOT NULL,
    event_type_id smallint NOT NULL,
    events        bigint   NOT NULL,
    users         bigint   NOT NULL,
    PRIMARY KEY (tenant_id, day, event_type_id)
);

CREATE TABLE rollup_state (
    name      text        PRIMARY KEY,
    watermark timestamptz NOT NULL            -- events before this are rolled up
);

-- Idempotent: safe to re-run over any window. Days are UTC days.
--   refresh_rollups()                        -- incremental: watermark - 1 day .. now()
--   refresh_rollups('1970-01-01')            -- full rebuild from whatever raw data exists
CREATE OR REPLACE FUNCTION refresh_rollups(
    p_from timestamptz DEFAULT NULL,
    p_to   timestamptz DEFAULT now())
RETURNS TABLE (step text, rows_affected bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_wm   timestamptz;
    v_from timestamptz;
    n      bigint;
BEGIN
    IF p_from IS NULL THEN
        SELECT watermark INTO v_wm FROM rollup_state WHERE name = 'events_rollups';
        p_from := coalesce(v_wm - interval '1 day', 'epoch'::timestamptz);  -- 1 day of late-arrival slack
    END IF;
    -- start at the beginning of the UTC day so a day is always recomputed whole
    v_from := date_trunc('day', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';

    INSERT INTO agg_daily_active_users (tenant_id, day, dau)
    SELECT tenant_id, (occurred_at AT TIME ZONE 'UTC')::date, count(DISTINCT user_id)
    FROM events
    WHERE occurred_at >= v_from AND occurred_at < p_to
    GROUP BY 1, 2
    ON CONFLICT (tenant_id, day) DO UPDATE SET dau = EXCLUDED.dau;
    GET DIAGNOSTICS n = ROW_COUNT;  step := 'agg_daily_active_users'; rows_affected := n; RETURN NEXT;

    INSERT INTO agg_daily_events (tenant_id, day, event_type_id, events, users)
    SELECT tenant_id, (occurred_at AT TIME ZONE 'UTC')::date, event_type_id,
           count(*), count(DISTINCT user_id)
    FROM events
    WHERE occurred_at >= v_from AND occurred_at < p_to
    GROUP BY 1, 2, 3
    ON CONFLICT (tenant_id, day, event_type_id)
        DO UPDATE SET events = EXCLUDED.events, users = EXCLUDED.users;
    GET DIAGNOSTICS n = ROW_COUNT;  step := 'agg_daily_events'; rows_affected := n; RETURN NEXT;

    -- min/max merge is idempotent AND keeps history after raw partitions are dropped
    INSERT INTO agg_user_activity (tenant_id, user_id, first_event_at, last_event_at)
    SELECT tenant_id, user_id, min(occurred_at), max(occurred_at)
    FROM events
    WHERE occurred_at >= v_from AND occurred_at < p_to
    GROUP BY 1, 2
    ON CONFLICT (tenant_id, user_id) DO UPDATE
        SET first_event_at = least(agg_user_activity.first_event_at, EXCLUDED.first_event_at),
            last_event_at  = greatest(agg_user_activity.last_event_at, EXCLUDED.last_event_at);
    GET DIAGNOSTICS n = ROW_COUNT;  step := 'agg_user_activity'; rows_affected := n; RETURN NEXT;

    INSERT INTO rollup_state (name, watermark) VALUES ('events_rollups', p_to)
    ON CONFLICT (name) DO UPDATE
        SET watermark = greatest(rollup_state.watermark, EXCLUDED.watermark);
END $$;

-- ===================================== tenant-safe access to the pre-aggregates
-- Materialized views and plain aggregate tables do NOT support RLS, so the
-- dashboard role gets no direct grant on them. It reads these views instead; each
-- one filters on the request's tenant (security_barrier stops filter push-down
-- from leaking other tenants' rows through leaky functions).
CREATE VIEW v_user_activity WITH (security_barrier = true) AS
    SELECT * FROM agg_user_activity      WHERE tenant_id = current_tenant_id();
CREATE VIEW v_daily_active_users WITH (security_barrier = true) AS
    SELECT * FROM agg_daily_active_users WHERE tenant_id = current_tenant_id();
CREATE VIEW v_daily_events WITH (security_barrier = true) AS
    SELECT * FROM agg_daily_events       WHERE tenant_id = current_tenant_id();
CREATE VIEW v_daily_revenue WITH (security_barrier = true) AS
    SELECT * FROM mv_daily_revenue       WHERE tenant_id = current_tenant_id();

GRANT SELECT ON v_user_activity, v_daily_active_users, v_daily_events, v_daily_revenue
    TO app_dashboard;

-- monitoring: the exporter's login (monitor_svc) joins this role. It can see the
-- rollup watermark and nothing else of ours (pg_monitor covers the statistics views).
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_monitor') THEN
        CREATE ROLE app_monitor NOLOGIN;
    END IF;
END $$;
GRANT USAGE ON SCHEMA public TO app_monitor;
GRANT SELECT ON rollup_state TO app_monitor;

-- first population (the demo data from V5)
SELECT * FROM refresh_rollups('1970-01-01');
