-- V5__seed_demo_data.sql
-- Reference data + a deterministic demo-data generator.
--
--   * This migration seeds a SMALL dataset (2,000 users, ~50k events) so that
--     `flyway clean migrate` stays fast.
--   * The same generator makes the benchmark dataset:
--         SELECT * FROM seed_demo_data(100000, 115, 90, true);   -- ~10.3M events
--     (see scripts/load_bulk_data.sh)
--
-- Realism built into the generator (so the analytics have something to find):
--   * signups ramp up over time (growth), 10 tenants of very different size
--   * each user has an exponential "lifetime": engagement events stop after it
--     (this produces a believable retention curve, differing by acquisition channel)
--   * funnel: signup -> view_pricing (~60%) -> start_trial (~40%) -> purchase (~45%)
--   * purchasers get a subscription and monthly payments (some failed / refunded)
--   * events are inserted ORDERED BY occurred_at, like real ingestion, which is what
--     makes the BRIN index on occurred_at effective.

-- ------------------------------------------------------------ reference data
INSERT INTO plans (plan_id, name, monthly_price_cents) VALUES
    (1, 'free',        0),
    (2, 'starter',  1900),
    (3, 'pro',      4900),
    (4, 'business', 19900);

INSERT INTO event_types (event_type_id, name, category) VALUES
    (1, 'signup',       'acquisition'),
    (2, 'view_pricing', 'activation'),
    (3, 'start_trial',  'activation'),
    (4, 'purchase',     'revenue'),
    (5, 'login',        'engagement'),
    (6, 'page_view',    'engagement'),
    (7, 'feature_used', 'engagement'),
    (8, 'invite_sent',  'engagement');

INSERT INTO tenants (name, plan_id) VALUES
    ('Acme Notes',      4), ('Globex CRM',     4), ('Initech Tasks',  3),
    ('Umbrella Fit',    3), ('Hooli Docs',     3), ('Stark Budget',   2),
    ('Wayne Learn',     2), ('Wonka Shop',     2), ('Soylent Eats',   2),
    ('Cyberdyne Chat',  1);

INSERT INTO funnels (tenant_id, name, window_hours)
SELECT tenant_id, 'Signup to Purchase', 168 FROM tenants;

INSERT INTO funnel_steps (funnel_id, step_order, event_type_id)
SELECT f.funnel_id, s.step_order, s.event_type_id
FROM funnels f
CROSS JOIN (VALUES (1, 1), (2, 2), (3, 3), (4, 4)) AS s (step_order, event_type_id);

-- ------------------------------------------------------------ data generator
CREATE OR REPLACE FUNCTION seed_demo_data(
    p_total_users int,
    p_avg_events  int,
    p_days        int     DEFAULT 90,
    p_reset       boolean DEFAULT false)
RETURNS TABLE (users_created bigint, events_created bigint,
               subscriptions_created bigint, payments_created bigint)
LANGUAGE plpgsql
SET work_mem = '256MB'
AS $$
DECLARE
    v_end      timestamptz := date_trunc('hour', now());
    v_start    timestamptz := date_trunc('hour', now()) - make_interval(days => p_days);
    v_tenants  int[];
    v_weights  numeric[] := ARRAY[0.25, 0.18, 0.13, 0.11, 0.09, 0.07, 0.06, 0.04, 0.04, 0.03];
    v_cum      numeric[] := ARRAY[]::numeric[];
    v_n        int;
    v_sum      numeric;
    v_acc      numeric := 0;
    v_max_sub  bigint;
    v_users    bigint;
    v_events   bigint;
    v_subs     bigint;
    v_pays     bigint;
    i          int;
BEGIN
    PERFORM setseed(0.42);                        -- reproducible data

    IF p_reset THEN
        TRUNCATE payments, subscriptions, events, end_users RESTART IDENTITY;
        ALTER SEQUENCE end_users_user_id_seq RESTART;
        ALTER SEQUENCE events_event_id_seq   RESTART;
        IF to_regclass('agg_user_activity') IS NOT NULL THEN
            TRUNCATE agg_user_activity, agg_daily_active_users, agg_daily_events, rollup_state;
        END IF;
    END IF;

    -- do not flood the audit log with generated rows
    ALTER TABLE subscriptions DISABLE TRIGGER subscriptions_audit;
    ALTER TABLE payments      DISABLE TRIGGER payments_audit;

    SELECT array_agg(tenant_id ORDER BY tenant_id) INTO v_tenants FROM tenants;
    v_n := least(coalesce(array_length(v_tenants, 1), 0), array_length(v_weights, 1));
    IF v_n = 0 THEN
        RAISE EXCEPTION 'seed_demo_data: no tenants';
    END IF;
    SELECT sum(w) INTO v_sum FROM unnest(v_weights[1:v_n]) AS w;
    FOR i IN 1..v_n LOOP
        v_acc := v_acc + v_weights[i] / v_sum;
        v_cum := v_cum || v_acc;
    END LOOP;
    v_cum[v_n] := 1.01;                           -- guard against rounding

    PERFORM ensure_events_partitions(v_start::date, v_end::date);

    -- ------------------------------------------------------------ users
    CREATE TEMP TABLE seed_stage_users ON COMMIT DROP AS
    SELECT v_tenants[(SELECT min(k) FROM generate_subscripts(v_cum, 1) AS k
                      WHERE v_cum[k] >= (g - 0.5) / p_total_users)]          AS tenant_id,
           'u_' || g || '_' || extract(epoch FROM clock_timestamp())::bigint  AS external_id,
           g,
           (ARRAY['US','GB','DE','KE','IN','BR','NG','FR'])
               [1 + floor(power(random(), 1.5) * 8)::int]                    AS country_code,
           CASE WHEN c < 0.40 THEN 'organic'
                WHEN c < 0.65 THEN 'paid_search'
                WHEN c < 0.85 THEN 'social'
                ELSE 'referral' END                                          AS channel,
           v_start + (v_end - v_start) * power(random(), 0.7)                AS signup_at,
           random()                                                          AS r_life,
           random()                                                          AS r_n
    FROM (SELECT g, random() AS c FROM generate_series(1, p_total_users) AS g) gen;

    INSERT INTO end_users (tenant_id, external_id, email_hash, country_code,
                           acquisition_channel, signup_at)
    SELECT tenant_id, external_id,
           hmac('user' || g || '@example.com', 'demo-pepper-change-me', 'sha256'),
           country_code, channel, signup_at
    FROM seed_stage_users;
    GET DIAGNOSTICS v_users = ROW_COUNT;

    CREATE TEMP TABLE seed_users ON COMMIT DROP AS
    SELECT s.tenant_id, u.user_id, s.signup_at, s.channel,
           -- mean lifetime (days) depends on channel: referral users stick around
           -ln(1.0 - s.r_life) * CASE s.channel WHEN 'referral' THEN 28
                                                 WHEN 'organic'  THEN 22
                                                 WHEN 'social'   THEN 16
                                                 ELSE 14 END                 AS lifetime_days,
           greatest(3, round(p_avg_events * (0.25 + 1.5 * s.r_n))::int)      AS n_events
    FROM seed_stage_users s
    JOIN end_users u ON u.tenant_id = s.tenant_id AND u.external_id = s.external_id;

    -- ----------------------------------------------------------- funnel
    CREATE TEMP TABLE seed_funnel ON COMMIT DROP AS
    WITH r AS MATERIALIZED (
        SELECT tenant_id, user_id, signup_at,
               CASE channel WHEN 'referral' THEN 1.25 WHEN 'organic' THEN 1.0
                            WHEN 'social' THEN 0.85 ELSE 0.9 END AS cm,
               random() AS a, random() AS b, random() AS c,
               random() AS d, random() AS e, random() AS f
        FROM seed_users),
    s2 AS (SELECT r.*, CASE WHEN a < 0.60 * cm THEN signup_at + b * interval '2 days' END AS t2 FROM r),
    s3 AS (SELECT s2.*, CASE WHEN t2 IS NOT NULL AND c < 0.40 THEN t2 + d * interval '3 days' END AS t3 FROM s2),
    s4 AS (SELECT s3.*, CASE WHEN t3 IS NOT NULL AND e < 0.45 THEN t3 + f * interval '7 days' END AS t4 FROM s3)
    SELECT tenant_id, user_id, signup_at AS t1, t2, t3, t4 FROM s4;

    -- ------------------------------------------------- stage all events
    CREATE TEMP TABLE seed_stage (
        tenant_id     int,
        user_id       bigint,
        event_type_id smallint,
        occurred_at   timestamptz
    ) ON COMMIT DROP;

    INSERT INTO seed_stage
    SELECT tenant_id, user_id, 1, t1 FROM seed_funnel WHERE t1 < v_end
    UNION ALL SELECT tenant_id, user_id, 2, t2 FROM seed_funnel WHERE t2 < v_end
    UNION ALL SELECT tenant_id, user_id, 3, t3 FROM seed_funnel WHERE t3 < v_end
    UNION ALL SELECT tenant_id, user_id, 4, t4 FROM seed_funnel WHERE t4 < v_end;

    INSERT INTO seed_stage
    SELECT x.tenant_id, x.user_id,
           CASE WHEN x.r < 0.15 THEN 5 WHEN x.r < 0.65 THEN 6
                WHEN x.r < 0.95 THEN 7 ELSE 8 END,
           x.occurred_at
    FROM (SELECT u.tenant_id, u.user_id, random() AS r,
                 u.signup_at + interval '1 minute'
                   + power(random(), 1.5) * u.lifetime_days * interval '1 day' AS occurred_at
          FROM seed_users u
          CROSS JOIN LATERAL generate_series(1, u.n_events) AS g) x
    WHERE x.occurred_at < v_end;

    -- time-ordered insert -> physical order == time order (BRIN-friendly)
    INSERT INTO events (tenant_id, user_id, event_type_id, occurred_at, session_id, properties)
    SELECT s.tenant_id, s.user_id, s.event_type_id, s.occurred_at,
           md5(s.user_id::text || ':' || ((s.occurred_at AT TIME ZONE 'UTC')::date)::text)::uuid,
           jsonb_build_object(
               'device',      (ARRAY['desktop','mobile','tablet'])[1 + floor(random() * 3)::int],
               'app_version', (ARRAY['3.1','3.2','4.0'])[1 + floor(random() * 3)::int])
           || CASE WHEN random() < 0.01
                   THEN '{"campaign": "autumn_sale"}'::jsonb
                   ELSE '{}'::jsonb END
    FROM seed_stage s
    ORDER BY s.occurred_at;
    GET DIAGNOSTICS v_events = ROW_COUNT;

    -- ---------------------------------------------- subscriptions + payments
    SELECT coalesce(max(subscription_id), 0) INTO v_max_sub FROM subscriptions;

    INSERT INTO subscriptions (tenant_id, user_id, plan_id, status, started_at, ended_at)
    SELECT q.tenant_id, q.user_id,
           CASE WHEN q.rp < 0.6 THEN 2 WHEN q.rp < 0.9 THEN 3 ELSE 4 END,
           CASE WHEN q.rc < 0.20 THEN 'canceled' WHEN q.rc < 0.23 THEN 'past_due' ELSE 'active' END,
           q.t4,
           CASE WHEN q.rc < 0.20 THEN least(q.t4 + q.rd * 60 * interval '1 day', v_end) END
    FROM (SELECT f.*, random() AS rp, random() AS rc, random() AS rd
          FROM seed_funnel f WHERE f.t4 IS NOT NULL AND f.t4 < v_end) q;
    GET DIAGNOSTICS v_subs = ROW_COUNT;

    INSERT INTO payments (subscription_id, tenant_id, amount_cents, currency, status, paid_at)
    SELECT s.subscription_id, s.tenant_id, p.monthly_price_cents, 'USD',
           CASE WHEN x.r < 0.94 THEN 'succeeded' WHEN x.r < 0.97 THEN 'failed' ELSE 'refunded' END,
           s.started_at + x.m * interval '1 month'
    FROM subscriptions s
    JOIN plans p ON p.plan_id = s.plan_id
    CROSS JOIN LATERAL (SELECT m, random() AS r FROM generate_series(0, 12) AS m) x
    WHERE s.subscription_id > v_max_sub
      AND s.started_at + x.m * interval '1 month' <= least(coalesce(s.ended_at, v_end), v_end);
    GET DIAGNOSTICS v_pays = ROW_COUNT;

    ALTER TABLE subscriptions ENABLE TRIGGER subscriptions_audit;
    ALTER TABLE payments      ENABLE TRIGGER payments_audit;

    ANALYZE end_users;
    ANALYZE events;
    ANALYZE subscriptions;
    ANALYZE payments;
    -- Small dimension tables too! Without statistics the planner guesses ~11 rows for
    -- funnel_steps (actual: 4) and picks a hash join over ~1.2M events instead of
    -- per-step index probes: Q1 measured 197 ms vs 21 ms after this ANALYZE.
    ANALYZE funnels;
    ANALYZE funnel_steps;
    ANALYZE tenants;
    ANALYZE plans;
    ANALYZE event_types;

    RETURN QUERY SELECT v_users, v_events, v_subs, v_pays;
END $$;

-- small demo dataset for the migration run
SELECT * FROM seed_demo_data(2000, 25, 90, false);
