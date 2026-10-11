-- Q1  FUNNEL CONVERSION
-- Question: of the users who signed up in the last 30 days, how many went
--           signup -> view_pricing -> start_trial -> purchase, each step inside the
--           funnel's time window and in order? (one tenant, funnel defined in the DB)
-- The same statement is benchmarked before and after: the optimisation is an index.
WITH f AS (
    SELECT funnel_id, make_interval(hours => window_hours) AS win
    FROM funnels
    WHERE tenant_id = :tenant AND name = 'Signup to Purchase'),
steps AS (
    SELECT fs.step_order, fs.event_type_id
    FROM funnel_steps fs JOIN f USING (funnel_id)),
hits AS (                                   -- first time each user reached each step
    SELECT e.user_id,
           min(e.occurred_at) FILTER (WHERE s.step_order = 1) AS t1,
           min(e.occurred_at) FILTER (WHERE s.step_order = 2) AS t2,
           min(e.occurred_at) FILTER (WHERE s.step_order = 3) AS t3,
           min(e.occurred_at) FILTER (WHERE s.step_order = 4) AS t4
    FROM events e
    JOIN steps s ON s.event_type_id = e.event_type_id
    WHERE e.tenant_id = :tenant
      AND e.occurred_at >= now() - interval '30 days'
      AND e.occurred_at <  now()
    GROUP BY e.user_id)
SELECT count(*) FILTER (WHERE a.r1) AS step1_signup,
       count(*) FILTER (WHERE a.r2) AS step2_view_pricing,
       count(*) FILTER (WHERE b.r3) AS step3_start_trial,
       count(*) FILTER (WHERE c.r4) AS step4_purchase,
       round(100.0 * count(*) FILTER (WHERE a.r2) / nullif(count(*) FILTER (WHERE a.r1), 0), 1) AS pct_signup_to_pricing,
       round(100.0 * count(*) FILTER (WHERE b.r3) / nullif(count(*) FILTER (WHERE a.r2), 0), 1) AS pct_pricing_to_trial,
       round(100.0 * count(*) FILTER (WHERE c.r4) / nullif(count(*) FILTER (WHERE b.r3), 0), 1) AS pct_trial_to_purchase,
       round(100.0 * count(*) FILTER (WHERE c.r4) / nullif(count(*) FILTER (WHERE a.r1), 0), 1) AS pct_overall
FROM hits h
CROSS JOIN f
CROSS JOIN LATERAL (SELECT h.t1 IS NOT NULL AS r1,
                           coalesce(h.t2 BETWEEN h.t1 AND h.t1 + f.win, false) AS r2) a
CROSS JOIN LATERAL (SELECT a.r2 AND coalesce(h.t3 BETWEEN h.t2 AND h.t2 + f.win, false) AS r3) b
CROSS JOIN LATERAL (SELECT b.r3 AND coalesce(h.t4 BETWEEN h.t3 AND h.t3 + f.win, false) AS r4) c;
